## AVX2 transform kernels. Only this translation unit targets AVX2.
import std/complex
import nimsimd/avx2

when defined(vcc):
  {.localPassC: "/arch:AVX2".}
else:
  {.localPassC: "-mavx2 -ffp-contract=off".}

{.push boundChecks: not defined(release), overflowChecks: not defined(release).}
proc fftStagesAvx2*(work: var openArray[Complex64], twiddles: openArray[Complex64]) =
  ## Applies the remaining radix-two stages to two complex butterflies at once.
  static: doAssert sizeof(Complex64) == 2 * sizeof(float64)
  var stride = 4
  while stride < work.len:
    for base in countup(0, work.high, 2 * stride):
      for j in countup(0, stride - 1, 2):
        let
          a = mm256_loadu_pd(addr work[base + j])
          b = mm256_loadu_pd(addr work[base + stride + j])
          w = mm256_loadu_pd(unsafeAddr twiddles[stride + j])
          real = mm256_mul_pd(b, mm256_movedup_pd(w))
          imag = mm256_mul_pd(mm256_permute_pd(b, 0b0101),
            mm256_permute_pd(w, 0b1111))
          rotated = mm256_addsub_pd(real, imag)
        mm256_storeu_pd(addr work[base + j], mm256_add_pd(a, rotated))
        mm256_storeu_pd(addr work[base + stride + j], mm256_sub_pd(a, rotated))
    stride *= 2
{.pop.}

type Lines = array[8, M128i]

proc transpose(x: var Lines) {.inline.} =
  ## Transposes eight rows of signed 16-bit coefficients in registers.
  var pairs, quads: Lines
  for i in 0 ..< 4:
    pairs[2*i] = mm_unpacklo_epi16(x[2*i], x[2*i+1])
    pairs[2*i+1] = mm_unpackhi_epi16(x[2*i], x[2*i+1])
  for i in [0, 4]:
    quads[i] = mm_unpacklo_epi32(pairs[i], pairs[i+2])
    quads[i+1] = mm_unpackhi_epi32(pairs[i], pairs[i+2])
    quads[i+2] = mm_unpacklo_epi32(pairs[i+1], pairs[i+3])
    quads[i+3] = mm_unpackhi_epi32(pairs[i+1], pairs[i+3])
  for i in 0 ..< 4:
    x[2*i] = mm_unpacklo_epi64(quads[i], quads[i+4])
    x[2*i+1] = mm_unpackhi_epi64(quads[i], quads[i+4])

proc transformLines(x: var Lines, finalPass: static bool) {.inline.} =
  ## Performs eight independent fixed-point transforms across 32-bit lanes.
  template widen(i: int): M256i = mm256_cvtepi16_epi32(x[i])
  template plus(a, b: M256i): M256i = mm256_add_epi32(a, b)
  template minus(a, b: M256i): M256i = mm256_sub_epi32(a, b)
  template wrap16(a: M256i): M256i =
    mm256_srai_epi32(mm256_slli_epi32(a, 16), 16)
  template mul(c: int32, v: M256i): M256i =
    mm256_srai_epi32(mm256_mullo_epi32(mm256_set1_epi32(c), v), 16)
  let
    even0 = mul(46341, wrap16(plus(widen(0), widen(4))))
    even1 = mul(46341, wrap16(minus(widen(0), widen(4))))
    even2 = minus(mul(25080, widen(2)), mul(60547, widen(6)))
    even3 = plus(mul(60547, widen(2)), mul(25080, widen(6)))
    odd0 = minus(mul(12785, widen(1)), mul(64277, widen(7)))
    odd1 = minus(mul(54491, widen(5)), mul(36410, widen(3)))
    odd2 = plus(mul(36410, widen(5)), mul(54491, widen(3)))
    odd3 = plus(mul(64277, widen(1)), mul(12785, widen(7)))
    e = plus(odd0, odd1)
    h = plus(odd3, odd2)
    g0 = mul(46341, wrap16(minus(odd3, odd2)))
    f0 = mul(46341, wrap16(minus(odd0, odd1)))
    a = plus(even0, even3)
    d = minus(even0, even3)
    b = plus(even1, even2)
    c = minus(even1, even2)
    g = plus(g0, f0)
    f = minus(g0, f0)
  template store(i: int, v: M256i) =
    var lane = wrap16(v)
    when finalPass:
      lane = mm256_srai_epi32(plus(lane, mm256_set1_epi32(8)), 4)
    x[i] = mm_packs_epi32(mm256_castsi256_si128(lane),
      mm256_extracti128_si256(lane, 1))
  store(0, plus(a, h))
  store(1, plus(b, g))
  store(2, plus(c, f))
  store(3, plus(d, e))
  store(4, minus(d, e))
  store(5, minus(c, f))
  store(6, minus(b, g))
  store(7, minus(a, h))

proc denseDctAvx2*(coefficients: var array[64, int16]) =
  ## Restores a dense 8x8 Theora block in horizontal then vertical order.
  var x: Lines
  for i in 0 ..< 8: x[i] = mm_loadu_si128(addr coefficients[8*i])
  transpose(x)
  transformLines(x, false)
  transpose(x)
  transformLines(x, true)
  for i in 0 ..< 8: mm_storeu_si128(addr coefficients[8*i], x[i])
