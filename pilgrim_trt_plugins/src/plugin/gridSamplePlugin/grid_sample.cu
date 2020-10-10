#include <cmath>
#include <algorithm>
#include <stdio.h>
#include <cuda_fp16.h>

#include "grid_sample.h"
#include "amir_cuda_util/cuda_util.h"

//// the code copy from https://github.com/pytorch/pytorch/blob/ec683299ebabf297a3504c76248d37be830e4342/aten/src/ATen/native/cuda/GridSampler.cuh 
//// and https://github.com/pytorch/pytorch/blob/ec683299ebabf297a3504c76248d37be830e4342/aten/src/ATen/native/cuda/GridSampler.cu

namespace amirstan
{
namespace plugin
{
    using namespace amirstan::cuda;

    // Unnormalizes a coordinate from the -1 to +1 scale to its pixel index value,
    // where we view each pixel as an area between (idx - 0.5) and (idx + 0.5).
    // if align_corners: -1 and +1 get sent to the centers of the corner pixels
    //     -1 --> 0
    //     +1 --> (size - 1)
    //     scale_factor = (size - 1) / 2
    // if not align_corners: -1 and +1 get sent to the image edges
    //     -1 --> -0.5
    //     +1 --> (size - 1) + 0.5 == size - 0.5
    //     scale_factor = size / 2
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t grid_sampler_unnormalize(scalar_t coord, int size, bool align_corners) {
    if (align_corners) {
        // unnormalize coord from [-1, 1] to [0, size - 1]
        return ((coord + 1.f) / 2) * (size - 1);
    } else {
        // unnormalize coord from [-1, 1] to [-0.5, size - 0.5]
        return ((coord + 1.f) * size - 1) / 2;
    }
    }

    // grid_sampler_unnormalize_set_grad works the same as grid_sampler_unnormalize
    // except that it also returns the `d output / d input` via pointer argument
    // `grad_in`.
    // This is useful in the backward pass of grid_sampler.
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t grid_sampler_unnormalize_set_grad(scalar_t coord, int size,
                                            bool align_corners, scalar_t *grad_in) {
    if (align_corners) {
        // unnormalize coord from [-1, 1] to [0, size - 1]
        *grad_in = static_cast<scalar_t>(size - 1) / 2;
        return ((coord + 1.f) / 2) * (size - 1);
    } else {
        // unnormalize coord from [-1, 1] to [-0.5, size - 0.5]
        *grad_in = static_cast<scalar_t>(size) / 2;
        return ((coord + 1.f) * size - 1) / 2;
    }
    }

    // Clips coordinates to between 0 and clip_limit - 1
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t clip_coordinates(scalar_t in, int clip_limit) {
    return ::min(static_cast<scalar_t>(clip_limit - 1), ::max(in, static_cast<scalar_t>(0)));
    }

    // clip_coordinates_set_grad works similarly to clip_coordinates except that
    // it also returns the `d output / d input` via pointer argument `grad_in`.
    // This is useful in the backward pass of grid_sampler.
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t clip_coordinates_set_grad(scalar_t in, int clip_limit, scalar_t *grad_in) {
    // Note that it is important for the gradient calculation that borders
    // are considered out of bounds.
    if (in <= static_cast<scalar_t>(0)) {
        *grad_in = static_cast<scalar_t>(0);
        return static_cast<scalar_t>(0);
    } else {
        scalar_t max = static_cast<scalar_t>(clip_limit - 1);
        if (in >= max) {
        *grad_in = static_cast<scalar_t>(0);
        return max;
        } else {
        *grad_in = static_cast<scalar_t>(1);
        return in;
        }
    }
    }

    // Reflects coordinates until they fall between low and high (inclusive).
    // The bounds are passed as twice their value so that half-integer values
    // can be represented as ints.
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t reflect_coordinates(scalar_t in, int twice_low, int twice_high) {
    if (twice_low == twice_high) {
        return static_cast<scalar_t>(0);
    }
    scalar_t min = static_cast<scalar_t>(twice_low) / 2;
    scalar_t span = static_cast<scalar_t>(twice_high - twice_low) / 2;
    in = ::fabs(in - min);
    // `fmod` returns same sign as `in`, which is positive after the `fabs` above.
    scalar_t extra = ::fmod(in, span);
    int flips = static_cast<int>(::floor(in / span));
    if (flips % 2 == 0) {
        return extra + min;
    } else {
        return span - extra + min;
    }
    }

    // reflect_coordinates_set_grad works similarly to reflect_coordinates except
    // that it also returns the `d output / d input` via pointer argument
    // `grad_in`.
    // This is useful in the backward pass of grid_sampler.
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t reflect_coordinates_set_grad(scalar_t in, int twice_low, int twice_high,
                                        scalar_t *grad_in) {
    if (twice_low == twice_high) {
        *grad_in = static_cast<scalar_t>(0);
        return static_cast<scalar_t>(0);
    }
    int grad_in_mult_;
    scalar_t min = static_cast<scalar_t>(twice_low) / 2;
    scalar_t span = static_cast<scalar_t>(twice_high - twice_low) / 2;
    in = in - min;
    if (in < static_cast<scalar_t>(0)) {
        grad_in_mult_ = -1;
        in = -in;
    } else {
        grad_in_mult_ = 1;
    }
    // `fmod` returns same sign as `in`, which is positive after the `if` above.
    scalar_t extra = ::fmod(in, span);
    int flips = static_cast<int>(::floor(in / span));
    if (flips % 2 == 0) {
        *grad_in = static_cast<scalar_t>(grad_in_mult_);
        return extra + min;
    } else {
        *grad_in = static_cast<scalar_t>(-grad_in_mult_);
        return span - extra + min;
    }
    }

    template<typename scalar_t> 
    static __forceinline__ __device__ 
    scalar_t safe_downgrade_to_int_range(scalar_t x){
    // -100.0 does not have special meaning. This is just to make sure 
    // it's not within_bounds_2d or within_bounds_3d, and does not cause 
    // undefined behavior. See #35506.  
    if (x > INT_MAX-1 || x < INT_MIN || !::isfinite(static_cast<double>(x))) 
        return static_cast<scalar_t>(-100.0); 
    return x;
    }

    // Computes the pixel source index value for a grid coordinate
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t grid_sampler_compute_source_index(
        scalar_t coord,
        int size,
        GridSamplerPadding padding_mode,
        bool align_corners) {
    coord = grid_sampler_unnormalize(coord, size, align_corners);
    if (padding_mode == GridSamplerPadding::Border) {
        // clip coordinates to image borders
        coord = clip_coordinates(coord, size);
    } else if (padding_mode == GridSamplerPadding::Reflection) {
        // reflect coordinates by image borders
        if (align_corners) {
        coord = reflect_coordinates(coord, 0, 2*(size - 1));
        } else {
        coord = reflect_coordinates(coord, -1, 2*size - 1);
        }
        // clip coordinates to image borders
        coord = clip_coordinates(coord, size);
    }

    coord = safe_downgrade_to_int_range(coord); 
    return coord;
    }

    // grid_sampler_compute_source_index_set_grad works similarly to
    // grid_sampler_compute_source_index except that it also returns the
    // `d output / d input` via pointer argument `grad_in`.
    // This is useful in the backward pass of grid_sampler.
    template <typename scalar_t>
    static __forceinline__ __device__
    scalar_t grid_sampler_compute_source_index_set_grad(
        scalar_t coord,
        int size,
        GridSamplerPadding padding_mode,
        bool align_corners,
        scalar_t *grad_in) {
    scalar_t grad_clip, grad_refl;
    coord = grid_sampler_unnormalize_set_grad(coord, size, align_corners, grad_in);
    if (padding_mode == GridSamplerPadding::Border) {
        // clip coordinates to image borders
        coord = clip_coordinates_set_grad(coord, size, &grad_clip);
        *grad_in = (*grad_in) * grad_clip;
    } else if (padding_mode == GridSamplerPadding::Reflection) {
        // reflect coordinates by image borders
        if (align_corners) {
        coord = reflect_coordinates_set_grad(coord, 0, 2*(size - 1), &grad_refl);
        } else {
        coord = reflect_coordinates_set_grad(coord, -1, 2*size - 1, &grad_refl);
        }
        // clip coordinates to image borders
        coord = clip_coordinates_set_grad(coord, size, &grad_clip);
        *grad_in = (*grad_in) * grad_refl * grad_clip;
    }

    coord = safe_downgrade_to_int_range(coord); 
    return coord;
    }

    static __forceinline__ __device__
    bool within_bounds_2d(int h, int w, int H, int W) {
    return h >= 0 && h < H && w >= 0 && w < W;
    }

    static __forceinline__ __device__
    bool within_bounds_3d(int d, int h, int w, int D, int H, int W) {
    return d >= 0 && d < D && h >= 0 && h < H && w >= 0 && w < W;
    }

    template<typename scalar_t>
    static __forceinline__ __device__
    void safe_add_2d(scalar_t *data, int h, int w,
                    int sH, int sW, int H, int W,
                    scalar_t delta) {
    if (within_bounds_2d(h, w, H, W)) {
        atomicAdd(data + h * sH + w * sW, delta);
    }
    }

    template<typename scalar_t>
    static __forceinline__ __device__
    void safe_add_3d(scalar_t *data, int d, int h, int w,
                    int sD, int sH, int sW, int D, int H, int W,
                    scalar_t delta) {
    if (within_bounds_3d(d, h, w, D, H, W)) {
        atomicAdd(data + d * sD + h * sH + w * sW, delta);
    }
    }



    using amirstan::cuda::TensorSize;
    using amirstan::cuda::TensorStride;

  template <typename scalar_t>
  __global__ void grid_sampler_2d_kernel(
      const int nthreads,
      const scalar_t *input,
      const scalar_t *grid,
      scalar_t *output,
      TensorSize input_size,
      TensorSize gride_size,
      TensorStride input_stride,
      TensorStride grid_stride,
      TensorStride output_stride,
      const GridSamplerInterpolation interpolation_mode,
      const GridSamplerPadding padding_mode,
      bool align_corners) {

    int C = input_size.size[1];
    int inp_H = input_size.size[2];
    int inp_W = input_size.size[3];
    int out_H = gride_size.size[1];
    int out_W = gride_size.size[2];
    int inp_sN = input_stride.size[0];
    int inp_sC = input_stride.size[1];
    int inp_sH = input_stride.size[2];
    int inp_sW = input_stride.size[3];
    int grid_sN = grid_stride.size[0];
    int grid_sH = grid_stride.size[1];
    int grid_sW = grid_stride.size[2];
    int grid_sCoor = grid_stride.size[3];
    int out_sN = output_stride.size[0];
    int out_sC = output_stride.size[1];
    int out_sH = output_stride.size[2];
    int out_sW = output_stride.size[3];

    CUDA_KERNEL_LOOP(index, nthreads) {
      const int w = index % out_W;
      const int h = (index / out_W) % out_H;
      const int n = index / (out_H * out_W);
      const int grid_offset = n * grid_sN + h * grid_sH + w * grid_sW;

      // get the corresponding input x, y co-ordinates from grid
      scalar_t ix = grid[grid_offset];
      scalar_t iy = grid[grid_offset + grid_sCoor];

      ix = grid_sampler_compute_source_index(ix, inp_W, padding_mode, align_corners);
      iy = grid_sampler_compute_source_index(iy, inp_H, padding_mode, align_corners);

      if (interpolation_mode == GridSamplerInterpolation::Bilinear) {
        // get NE, NW, SE, SW pixel values from (x, y)
        int ix_nw = static_cast<int>(::floor(ix));
        int iy_nw = static_cast<int>(::floor(iy));
        int ix_ne = ix_nw + 1;
        int iy_ne = iy_nw;
        int ix_sw = ix_nw;
        int iy_sw = iy_nw + 1;
        int ix_se = ix_nw + 1;
        int iy_se = iy_nw + 1;

        // get surfaces to each neighbor:
        scalar_t nw = (ix_se - ix)    * (iy_se - iy);
        scalar_t ne = (ix    - ix_sw) * (iy_sw - iy);
        scalar_t sw = (ix_ne - ix)    * (iy    - iy_ne);
        scalar_t se = (ix    - ix_nw) * (iy    - iy_nw);

        // calculate bilinear weighted pixel value and set output pixel
        auto inp_ptr_NC = input + n * inp_sN;
        auto out_ptr_NCHW = output + n * out_sN + h * out_sH + w * out_sW;
        for (int c = 0; c < C; ++c, inp_ptr_NC += inp_sC, out_ptr_NCHW += out_sC) {
          *out_ptr_NCHW = static_cast<scalar_t>(0);
          if (within_bounds_2d(iy_nw, ix_nw, inp_H, inp_W)) {
            *out_ptr_NCHW += inp_ptr_NC[iy_nw * inp_sH + ix_nw * inp_sW] * nw;
          }
          if (within_bounds_2d(iy_ne, ix_ne, inp_H, inp_W)) {
            *out_ptr_NCHW += inp_ptr_NC[iy_ne * inp_sH + ix_ne * inp_sW] * ne;
          }
          if (within_bounds_2d(iy_sw, ix_sw, inp_H, inp_W)) {
            *out_ptr_NCHW += inp_ptr_NC[iy_sw * inp_sH + ix_sw * inp_sW] * sw;
          }
          if (within_bounds_2d(iy_se, ix_se, inp_H, inp_W)) {
            *out_ptr_NCHW += inp_ptr_NC[iy_se * inp_sH + ix_se * inp_sW] * se;
          }
        }
      } else if (interpolation_mode == GridSamplerInterpolation::Nearest) {
        int ix_nearest = static_cast<int>(::round(ix));
        int iy_nearest = static_cast<int>(::round(iy));

        // assign nearest neighor pixel value to output pixel
        auto inp_ptr_NC = input + n * inp_sN;
        auto out_ptr_NCHW = output + n * out_sN + h * out_sH + w * out_sW;
        for (int c = 0; c < C; ++c, inp_ptr_NC += inp_sC, out_ptr_NCHW += out_sC) {
          if (within_bounds_2d(iy_nearest, ix_nearest, inp_H, inp_W)) {
            *out_ptr_NCHW = inp_ptr_NC[iy_nearest * inp_sH + ix_nearest * inp_sW];
          } else {
            *out_ptr_NCHW = static_cast<scalar_t>(0);
          }
        }
      }
    }
  }

  template <typename scalar_t>
  __global__ void grid_sampler_3d_kernel(
      const int nthreads,
      const scalar_t *input,
      const scalar_t *grid,
      scalar_t *output,
      TensorSize input_size,
      TensorSize gride_size,
      TensorStride input_stride,
      TensorStride grid_stride,
      TensorStride output_stride,
      const GridSamplerInterpolation interpolation_mode,
      const GridSamplerPadding padding_mode,
      bool align_corners) {

    int C = input_size.size[1];
    int inp_D = input_size.size[2];
    int inp_H = input_size.size[3];
    int inp_W = input_size.size[4];
    int out_D = gride_size.size[1];
    int out_H = gride_size.size[2];
    int out_W = gride_size.size[3];
    int inp_sN = input_stride.size[0];
    int inp_sC = input_stride.size[1];
    int inp_sD = input_stride.size[2];
    int inp_sH = input_stride.size[3];
    int inp_sW = input_stride.size[4];
    int grid_sN = grid_stride.size[0];
    int grid_sD = grid_stride.size[1];
    int grid_sH = grid_stride.size[2];
    int grid_sW = grid_stride.size[3];
    int grid_sCoor = grid_stride.size[4];
    int out_sN = output_stride.size[0];
    int out_sC = output_stride.size[1];
    int out_sD = output_stride.size[2];
    int out_sH = output_stride.size[3];
    int out_sW = output_stride.size[4];

    CUDA_KERNEL_LOOP(index, nthreads) {
      const int w = index % out_W;
      const int h = (index / out_W) % out_H;
      const int d = (index / (out_H * out_W)) % out_D;
      const int n = index / (out_D * out_H * out_W);
      const int grid_offset = n * grid_sN + d * grid_sD + h * grid_sH + w * grid_sW;

      // get the corresponding input x, y, z co-ordinates from grid
      scalar_t ix = grid[grid_offset];
      scalar_t iy = grid[grid_offset + grid_sCoor];
      scalar_t iz = grid[grid_offset + 2 * grid_sCoor];

      ix = grid_sampler_compute_source_index(ix, inp_W, padding_mode, align_corners);
      iy = grid_sampler_compute_source_index(iy, inp_H, padding_mode, align_corners);
      iz = grid_sampler_compute_source_index(iz, inp_D, padding_mode, align_corners);

      if (interpolation_mode == GridSamplerInterpolation::Bilinear) {
        // get corner pixel values from (x, y, z)
        // for 4d, we used north-east-south-west
        // for 5d, we add top-bottom
        int ix_tnw = static_cast<int>(::floor(ix));
        int iy_tnw = static_cast<int>(::floor(iy));
        int iz_tnw = static_cast<int>(::floor(iz));

        int ix_tne = ix_tnw + 1;
        int iy_tne = iy_tnw;
        int iz_tne = iz_tnw;

        int ix_tsw = ix_tnw;
        int iy_tsw = iy_tnw + 1;
        int iz_tsw = iz_tnw;

        int ix_tse = ix_tnw + 1;
        int iy_tse = iy_tnw + 1;
        int iz_tse = iz_tnw;

        int ix_bnw = ix_tnw;
        int iy_bnw = iy_tnw;
        int iz_bnw = iz_tnw + 1;

        int ix_bne = ix_tnw + 1;
        int iy_bne = iy_tnw;
        int iz_bne = iz_tnw + 1;

        int ix_bsw = ix_tnw;
        int iy_bsw = iy_tnw + 1;
        int iz_bsw = iz_tnw + 1;

        int ix_bse = ix_tnw + 1;
        int iy_bse = iy_tnw + 1;
        int iz_bse = iz_tnw + 1;

        // get surfaces to each neighbor:
        scalar_t tnw = (ix_bse - ix)    * (iy_bse - iy)    * (iz_bse - iz);
        scalar_t tne = (ix    - ix_bsw) * (iy_bsw - iy)    * (iz_bsw - iz);
        scalar_t tsw = (ix_bne - ix)    * (iy    - iy_bne) * (iz_bne - iz);
        scalar_t tse = (ix    - ix_bnw) * (iy    - iy_bnw) * (iz_bnw - iz);
        scalar_t bnw = (ix_tse - ix)    * (iy_tse - iy)    * (iz - iz_tse);
        scalar_t bne = (ix    - ix_tsw) * (iy_tsw - iy)    * (iz - iz_tsw);
        scalar_t bsw = (ix_tne - ix)    * (iy    - iy_tne) * (iz - iz_tne);
        scalar_t bse = (ix    - ix_tnw) * (iy    - iy_tnw) * (iz - iz_tnw);

        auto inp_ptr_NC = input + n * inp_sN;
        auto out_ptr_NCDHW = output + n * out_sN + d * out_sD + h * out_sH + w * out_sW;
        for (int c = 0; c < C; ++c, inp_ptr_NC += inp_sC, out_ptr_NCDHW += out_sC) {
          //   (c, iz_tnw, iy_tnw, ix_tnw) * tnw + (c, iz_tne, iy_tne, ix_tne) * tne
          // + (c, iz_tsw, iy_tsw, ix_tsw) * tsw + (c, iz_tse, iy_tse, ix_tse) * tse
          // + (c, iz_bnw, iy_bnw, ix_bnw) * bnw + (c, iz_bne, iy_bne, ix_bne) * bne
          // + (c, iz_bsw, iy_bsw, ix_bsw) * bsw + (c, iz_bse, iy_bse, ix_bse) * bse
          *out_ptr_NCDHW = static_cast<scalar_t>(0);
          if (within_bounds_3d(iz_tnw, iy_tnw, ix_tnw, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_tnw * inp_sD + iy_tnw * inp_sH + ix_tnw * inp_sW] * tnw;
          }
          if (within_bounds_3d(iz_tne, iy_tne, ix_tne, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_tne * inp_sD + iy_tne * inp_sH + ix_tne * inp_sW] * tne;
          }
          if (within_bounds_3d(iz_tsw, iy_tsw, ix_tsw, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_tsw * inp_sD + iy_tsw * inp_sH + ix_tsw * inp_sW] * tsw;
          }
          if (within_bounds_3d(iz_tse, iy_tse, ix_tse, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_tse * inp_sD + iy_tse * inp_sH + ix_tse * inp_sW] * tse;
          }
          if (within_bounds_3d(iz_bnw, iy_bnw, ix_bnw, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_bnw * inp_sD + iy_bnw * inp_sH + ix_bnw * inp_sW] * bnw;
          }
          if (within_bounds_3d(iz_bne, iy_bne, ix_bne, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_bne * inp_sD + iy_bne * inp_sH + ix_bne * inp_sW] * bne;
          }
          if (within_bounds_3d(iz_bsw, iy_bsw, ix_bsw, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_bsw * inp_sD + iy_bsw * inp_sH + ix_bsw * inp_sW] * bsw;
          }
          if (within_bounds_3d(iz_bse, iy_bse, ix_bse, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW += inp_ptr_NC[iz_bse * inp_sD + iy_bse * inp_sH + ix_bse * inp_sW] * bse;
          }
        }
      } else if (interpolation_mode == GridSamplerInterpolation::Nearest) {
        int ix_nearest = static_cast<int>(::round(ix));
        int iy_nearest = static_cast<int>(::round(iy));
        int iz_nearest = static_cast<int>(::round(iz));

        // assign nearest neighor pixel value to output pixel
        auto inp_ptr_NC = input + n * inp_sN;
        auto out_ptr_NCDHW = output + n * out_sN + d * out_sD + h * out_sH + w * out_sW;
        for (int c = 0; c < C; ++c, inp_ptr_NC += inp_sC, out_ptr_NCDHW += out_sC) {
          if (within_bounds_3d(iz_nearest, iy_nearest, ix_nearest, inp_D, inp_H, inp_W)) {
            *out_ptr_NCDHW = inp_ptr_NC[iz_nearest * inp_sD + iy_nearest * inp_sH + ix_nearest * inp_sW];
          } else {
            *out_ptr_NCDHW = static_cast<scalar_t>(0);
          }
        }
      }
    }
  }


  void create_size_stride(const int* dims, int nb_dims, TensorSize &size, TensorStride& stride){
        memcpy(&size.size[0], dims, sizeof(int)*nb_dims);
        stride.size[nb_dims-1] = 1;
        for(int i=nb_dims-2; i>=0; --i){
            stride.size[i] = stride.size[i+1] * size.size[i+1];
        }
  }


  template <typename T>
  void grid_sample(T *output, const T* input, const T* grid, 
                  int* output_dims, int* input_dims, int *grid_dims, int nb_dims,
                  GridSamplerInterpolation interp, GridSamplerPadding padding,
                  bool align_corners,
                  cudaStream_t stream){
        
        TensorSize ts_input_size;
        TensorStride input_stride;
        create_size_stride(input_dims, nb_dims, ts_input_size, input_stride);

        TensorSize ts_output_size;
        TensorStride output_stride;
        create_size_stride(output_dims, nb_dims, ts_output_size, output_stride);

        TensorSize ts_grid_size;
        TensorStride grid_stride;
        create_size_stride(grid_dims, nb_dims, ts_grid_size, grid_stride);

        int count = ts_input_size.size[0];
        for(int i=1; i<nb_dims-1; ++i){
            count*=ts_grid_size.size[i];
        }

        if(nb_dims==4){
            grid_sampler_2d_kernel<T><<<GET_BLOCKS(count), CUDA_NUM_THREADS, 0, stream>>>(count,
                                                                                            input, grid, output,
                                                                                            ts_input_size, ts_grid_size,
                                                                                            input_stride, grid_stride, output_stride,
                                                                                            interp, padding, align_corners
                                                                                            );
        }else if(nb_dims==5){
            grid_sampler_3d_kernel<T><<<GET_BLOCKS(count), CUDA_NUM_THREADS, 0, stream>>>(count,
                                                                                            input, grid, output,
                                                                                            ts_input_size, ts_grid_size,
                                                                                            input_stride, grid_stride, output_stride,
                                                                                            interp, padding, align_corners
                                                                                            );
        }else{
            printf("input and grid dims should be 4 or 5\n");
        }
    }
    
  template void grid_sample<float>(float *output, const float* input, const float* grid, 
                  int* output_dims, int* input_dims, int *grid_dims, int nb_dims,
                  GridSamplerInterpolation interp, GridSamplerPadding padding,
                  bool align_corners,
                  cudaStream_t stream);
}   // namespace plugin
}   // namespace amirstan