## AArch64 NEON kernels for Vorbis FFT and Theora reconstruction.
## The integer IDCT follows the Xiph-derived transform in theoradct.nim.
## Copyright (C) 2002-2009 Xiph.org Foundation; see licenses/theora.txt.
import std/complex

{.emit: """
#include <arm_neon.h>
static inline float64x2x2_t ogg_load_complex(const double *p) {
  float64x2_t x = vld1q_f64(p), y = vld1q_f64(p + 2);
  float64x2x2_t result;
  result.val[0] = vuzp1q_f64(x, y);
  result.val[1] = vuzp2q_f64(x, y);
  return result;
}
static inline void ogg_store_complex(double *p, float64x2x2_t x) {
  vst1q_f64(p, vzip1q_f64(x.val[0], x.val[1]));
  vst1q_f64(p + 2, vzip2q_f64(x.val[0], x.val[1]));
}
static void ogg_fft_neon(double *work, const double *twiddles, NI length) {
  for (NI stride = 4; stride < length; stride *= 2) {
    for (NI base = 0; base < length; base += 2 * stride) {
      for (NI j = 0; j < stride; j += 2) {
        double *lo = work + 2 * (base + j);
        double *hi = lo + 2 * stride;
        float64x2x2_t a = ogg_load_complex(lo);
        float64x2x2_t b = ogg_load_complex(hi);
        float64x2x2_t t = ogg_load_complex(twiddles + 2 * (stride + j));
        float64x2_t re = vfmsq_f64(vmulq_f64(b.val[0], t.val[0]),
                                  b.val[1], t.val[1]);
        float64x2_t im = vfmaq_f64(vmulq_f64(b.val[0], t.val[1]),
                                  b.val[1], t.val[0]);
        float64x2x2_t sum, diff;
        sum.val[0] = vaddq_f64(a.val[0], re);
        sum.val[1] = vaddq_f64(a.val[1], im);
        diff.val[0] = vsubq_f64(a.val[0], re);
        diff.val[1] = vsubq_f64(a.val[1], im);
        ogg_store_complex(lo, sum);
        ogg_store_complex(hi, diff);
      }
    }
  }
}

/* Fixed-point transforms preserve the scalar codec's signed wrap points. */
static inline int32x4_t ogg_wrap16(int32x4_t x) {
  return vmovl_s16(vmovn_s32(x));
}
static inline int32x4_t ogg_mul(int32x4_t x, int32_t c) {
  return vshrq_n_s32(vmulq_n_s32(x, c), 16);
}
static inline void ogg_transpose(int16x8_t *x) {
  int16x8_t p[8], q[8];
  p[0] = vzip1q_s16(x[0], x[1]);
  p[1] = vzip2q_s16(x[0], x[1]);
  p[2] = vzip1q_s16(x[2], x[3]);
  p[3] = vzip2q_s16(x[2], x[3]);
  p[4] = vzip1q_s16(x[4], x[5]);
  p[5] = vzip2q_s16(x[4], x[5]);
  p[6] = vzip1q_s16(x[6], x[7]);
  p[7] = vzip2q_s16(x[6], x[7]);
  q[0] = vreinterpretq_s16_s32(vzip1q_s32(vreinterpretq_s32_s16(p[0]), vreinterpretq_s32_s16(p[2])));
  q[1] = vreinterpretq_s16_s32(vzip2q_s32(vreinterpretq_s32_s16(p[0]), vreinterpretq_s32_s16(p[2])));
  q[2] = vreinterpretq_s16_s32(vzip1q_s32(vreinterpretq_s32_s16(p[1]), vreinterpretq_s32_s16(p[3])));
  q[3] = vreinterpretq_s16_s32(vzip2q_s32(vreinterpretq_s32_s16(p[1]), vreinterpretq_s32_s16(p[3])));
  q[4] = vreinterpretq_s16_s32(vzip1q_s32(vreinterpretq_s32_s16(p[4]), vreinterpretq_s32_s16(p[6])));
  q[5] = vreinterpretq_s16_s32(vzip2q_s32(vreinterpretq_s32_s16(p[4]), vreinterpretq_s32_s16(p[6])));
  q[6] = vreinterpretq_s16_s32(vzip1q_s32(vreinterpretq_s32_s16(p[5]), vreinterpretq_s32_s16(p[7])));
  q[7] = vreinterpretq_s16_s32(vzip2q_s32(vreinterpretq_s32_s16(p[5]), vreinterpretq_s32_s16(p[7])));
  x[0] = vreinterpretq_s16_s64(vzip1q_s64(vreinterpretq_s64_s16(q[0]), vreinterpretq_s64_s16(q[4])));
  x[1] = vreinterpretq_s16_s64(vzip2q_s64(vreinterpretq_s64_s16(q[0]), vreinterpretq_s64_s16(q[4])));
  x[2] = vreinterpretq_s16_s64(vzip1q_s64(vreinterpretq_s64_s16(q[1]), vreinterpretq_s64_s16(q[5])));
  x[3] = vreinterpretq_s16_s64(vzip2q_s64(vreinterpretq_s64_s16(q[1]), vreinterpretq_s64_s16(q[5])));
  x[4] = vreinterpretq_s16_s64(vzip1q_s64(vreinterpretq_s64_s16(q[2]), vreinterpretq_s64_s16(q[6])));
  x[5] = vreinterpretq_s16_s64(vzip2q_s64(vreinterpretq_s64_s16(q[2]), vreinterpretq_s64_s16(q[6])));
  x[6] = vreinterpretq_s16_s64(vzip1q_s64(vreinterpretq_s64_s16(q[3]), vreinterpretq_s64_s16(q[7])));
  x[7] = vreinterpretq_s16_s64(vzip2q_s64(vreinterpretq_s64_s16(q[3]), vreinterpretq_s64_s16(q[7])));
}
static inline void ogg_transform(int16x8_t *x, int finalPass) {
  int16x4_t out[2][8];
  for (int half = 0; half < 2; ++half) {
    int32x4_t w[8];
    for (int i = 0; i < 8; ++i)
      w[i] = vmovl_s16(half ? vget_high_s16(x[i]) : vget_low_s16(x[i]));
#define A vaddq_s32
#define S vsubq_s32
#define M ogg_mul
#define W ogg_wrap16
    int32x4_t even0 = M(W(A(w[0],w[4])),46341);
    int32x4_t even1 = M(W(S(w[0],w[4])),46341);
    int32x4_t even2 = S(M(w[2],25080),M(w[6],60547));
    int32x4_t even3 = A(M(w[2],60547),M(w[6],25080));
    int32x4_t odd0 = S(M(w[1],12785),M(w[7],64277));
    int32x4_t odd1 = S(M(w[5],54491),M(w[3],36410));
    int32x4_t odd2 = A(M(w[5],36410),M(w[3],54491));
    int32x4_t odd3 = A(M(w[1],64277),M(w[7],12785));
    int32x4_t e = A(odd0,odd1);
    int32x4_t h = A(odd3,odd2);
    int32x4_t g0 = M(W(S(odd3,odd2)),46341);
    int32x4_t f0 = M(W(S(odd0,odd1)),46341);
    int32x4_t a = A(even0,even3);
    int32x4_t d = S(even0,even3);
    int32x4_t b = A(even1,even2);
    int32x4_t c = S(even1,even2);
    int32x4_t g = A(g0,f0);
    int32x4_t f = S(g0,f0);
    int32x4_t r0 = W(A(a,h));
    if (finalPass) r0 = vshrq_n_s32(A(r0, vdupq_n_s32(8)), 4);
    out[half][0] = vmovn_s32(r0);
    int32x4_t r1 = W(A(b,g));
    if (finalPass) r1 = vshrq_n_s32(A(r1, vdupq_n_s32(8)), 4);
    out[half][1] = vmovn_s32(r1);
    int32x4_t r2 = W(A(c,f));
    if (finalPass) r2 = vshrq_n_s32(A(r2, vdupq_n_s32(8)), 4);
    out[half][2] = vmovn_s32(r2);
    int32x4_t r3 = W(A(d,e));
    if (finalPass) r3 = vshrq_n_s32(A(r3, vdupq_n_s32(8)), 4);
    out[half][3] = vmovn_s32(r3);
    int32x4_t r4 = W(S(d,e));
    if (finalPass) r4 = vshrq_n_s32(A(r4, vdupq_n_s32(8)), 4);
    out[half][4] = vmovn_s32(r4);
    int32x4_t r5 = W(S(c,f));
    if (finalPass) r5 = vshrq_n_s32(A(r5, vdupq_n_s32(8)), 4);
    out[half][5] = vmovn_s32(r5);
    int32x4_t r6 = W(S(b,g));
    if (finalPass) r6 = vshrq_n_s32(A(r6, vdupq_n_s32(8)), 4);
    out[half][6] = vmovn_s32(r6);
    int32x4_t r7 = W(S(a,h));
    if (finalPass) r7 = vshrq_n_s32(A(r7, vdupq_n_s32(8)), 4);
    out[half][7] = vmovn_s32(r7);
#undef A
#undef S
#undef M
#undef W
  }
  for (int i = 0; i < 8; ++i) x[i] = vcombine_s16(out[0][i], out[1][i]);
}
static void ogg_dense_dct_neon(int16_t *coefficients) {
  int16x8_t x[8];
  for (int i = 0; i < 8; ++i) x[i] = vld1q_s16(coefficients + 8*i);
  ogg_transpose(x);
  ogg_transform(x, 0);
  ogg_transpose(x);
  ogg_transform(x, 1);
  for (int i = 0; i < 8; ++i) vst1q_s16(coefficients + 8*i, x[i]);
}
static void ogg_write_block_neon(uint8_t *dest, NI stride,
    const int16_t *residual, const uint8_t *a, const uint8_t *b) {
  for (int row = 0; row < 8; ++row) {
    uint8x8_t prediction;
    if (!a) prediction = vdup_n_u8(128);
    else if (a == b) prediction = vld1_u8(a - row*stride);
    else prediction = vhadd_u8(vld1_u8(a - row*stride),
                               vld1_u8(b - row*stride));
    int16x8_t sum = vqaddq_s16(vreinterpretq_s16_u16(vmovl_u8(prediction)),
                              vld1q_s16(residual + 8*row));
    vst1_u8(dest - row*stride, vqmovun_s16(sum));
  }
}

""".}
proc fftNeon(work, twiddles: ptr float64, length: int)
  {.importc: "ogg_fft_neon", nodecl.}

proc fftStagesNeon*(work: var openArray[Complex64],
    twiddles: openArray[Complex64]) =
  ## Processes two complex butterflies per vector after the first two stages.
  static: doAssert sizeof(Complex64) == 2 * sizeof(float64)
  fftNeon(cast[ptr float64](addr work[0]),
    cast[ptr float64](unsafeAddr twiddles[0]), work.len)

proc denseDctNeonRaw(coefficients: ptr int16)
  {.importc: "ogg_dense_dct_neon", nodecl.}
proc writeBlockNeonRaw(dest: ptr uint8, stride: int, residual: ptr int16,
    a, b: ptr uint8) {.importc: "ogg_write_block_neon", nodecl.}

proc denseDctNeon*(coefficients: var array[64, int16]) =
  ## Restores a dense 8x8 block with the normative integer wrap and shift rules.
  denseDctNeonRaw(addr coefficients[0])

proc writeBlockNeon*(dest: var openArray[uint8], offset, stride: int,
    residual: array[64, int16], reference: openArray[uint8], a, b: int) =
  ## Adds intra or motion prediction, clips, and writes eight bottom-up rows.
  assert stride in 8 .. 4096 and offset >= 7*stride and offset <= dest.len - 8
  assert reference.len == 0 or (min(a, b) >= 7*stride and
    max(a, b) <= reference.len - 8)
  let first = if reference.len == 0: nil else: unsafeAddr reference[a]
  let second = if reference.len == 0: nil else: unsafeAddr reference[b]
  writeBlockNeonRaw(addr dest[offset], stride, unsafeAddr residual[0],
    first, second)
