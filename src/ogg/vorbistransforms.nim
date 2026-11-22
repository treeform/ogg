import std/[complex, math]
import profiles, simd
when useX86Simd: import kernelsavx2

type MdctPlan* = object
  reverse: seq[int]
  rotation, twiddles: seq[Complex64]

proc initPlan(length: int): MdctPlan =
  ## Prepares rotations and FFT indices for one Vorbis block size.
  result.reverse.setLen(length)
  result.rotation.setLen(length)
  result.twiddles.setLen(length)
  let step = PI / float64(2 * length)
  var phase = rect(1.0, step / 8)
  let increment = rect(1.0, step)
  for i in 0 ..< length:
    result.reverse[i] = (result.reverse[i shr 1] shr 1) or
      ((i and 1) * (length shr 1))
    result.rotation[i] = phase
    phase *= increment
  var half = 1
  while half < length:
    let increment = rect(1.0, PI / float64(half))
    phase = complex64(1, 0)
    for i in 0 ..< half:
      result.twiddles[half + i] = phase
      phase *= increment
    half *= 2

proc rotate(a, b: Complex64): Complex64 {.inline, raises: [].} =
  ## Multiplies a sample by a precomputed unit rotation.
  Complex64(re: a.re*b.re - a.im*b.im, im: a.re*b.im + a.im*b.re)

{.push boundChecks: not defined(release), overflowChecks: not defined(release).}
proc fft(work: var openArray[Complex64], twiddles: openArray[Complex64]) =
  ## Applies radix-two butterflies to the bit-reversed input.
  # The plan and work buffer have the same power-of-two length, at most
  # 2048. Each stage partitions work into complete groups of 2*stride.
  # The first two stages use the exact rotations 1 and i.
  for base in countup(0, work.high, 4):
    let
      a = work[base]
      b = work[base + 1]
      c = work[base + 2]
      d = work[base + 3]
      ar = a.re + b.re
      ai = a.im + b.im
      br = a.re - b.re
      bi = a.im - b.im
      cr = c.re + d.re
      ci = c.im + d.im
      dr = c.re - d.re
      di = c.im - d.im
    work[base] = Complex64(re: ar + cr, im: ai + ci)
    work[base + 1] = Complex64(re: br - di, im: bi + dr)
    work[base + 2] = Complex64(re: ar - cr, im: ai - ci)
    work[base + 3] = Complex64(re: br + di, im: bi - dr)
  when useX86Simd:
    if hasAvx2:
      fftStagesAvx2(work, twiddles)
      return
  var stride = 4
  while stride < work.len:
    for base in countup(0, work.high, 2 * stride):
      for j in 0 ..< stride:
        let a = work[base + j]
        let b = rotate(work[base + j + stride], twiddles[stride + j])
        work[base + j] = Complex64(re: a.re + b.re, im: a.im + b.im)
        work[base + j + stride] = Complex64(re: a.re - b.re, im: a.im - b.im)
    stride *= 2

proc inverseMdct*(plan: var MdctPlan, work: var seq[Complex64],
    samples: var seq[float64]) {.measure.} =
  ## Replaces N/2 spectral coefficients with N time-domain samples.
  let half = samples.len
  doAssert half in 32 .. 4096 and (half and (half - 1)) == 0
  let length = half div 2
  if plan.rotation.len != length: plan = initPlan(length)
  work.setLen(length)
  # Even coefficients and reversed odd coefficients form the real and
  # imaginary parts of a single N/4-point transform.
  for i in 0 ..< length:
    let pair = Complex64(re: samples[2*i], im: -samples[half - 1 - 2*i])
    work[plan.reverse[i]] = rotate(pair, plan.rotation[i])
  fft(work, plan.twiddles)
  samples.setLen(2 * half)
  # Unfold the DCT-IV using its mirrored, sign-reversed continuation.
  template unfold(k: int, value: float64) =
    samples[3*length - 1 - k] = -value
    if k < length: samples[3*length + k] = -value
    else: samples[k - length] = value
  for i in 0 ..< length:
    let pair = rotate(work[i], plan.rotation[i])
    unfold(2*i, pair.re)
    unfold(half - 1 - 2*i, pair.im)
{.pop.}

proc initWindow*(length: int): seq[float64] =
  ## Returns the rising half of the Vorbis overlap window.
  result.setLen(length)
  for i in 0 ..< length:
    let a = sin((PI * 0.5 / float64(length)) * (float64(i) + 0.5))
    result[i] = sin(PI * 0.5 * a * a)
