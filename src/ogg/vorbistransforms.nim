import std/[complex, math]

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

proc inverseMdct*(plan: var MdctPlan, work: var seq[Complex64],
    samples: var seq[float64]) =
  ## Replaces N/2 spectral coefficients with N time-domain samples.
  let half = samples.len
  let length = half div 2
  if plan.rotation.len != length: plan = initPlan(length)
  work.setLen(length)
  # Even coefficients and reversed odd coefficients form the real and
  # imaginary parts of a single N/4-point transform.
  for i in 0 ..< length:
    let pair = complex64(samples[2*i], -samples[half - 1 - 2*i])
    work[plan.reverse[i]] = pair * plan.rotation[i]
  var stride = 1
  while stride < length:
    for base in countup(0, length - 1, 2 * stride):
      for j in 0 ..< stride:
        let a = work[base + j]
        let b = work[base + j + stride] * plan.twiddles[stride + j]
        work[base + j] = a + b
        work[base + j + stride] = a - b
    stride *= 2
  samples.setLen(2 * half)
  # Unfold the DCT-IV using its mirrored, sign-reversed continuation.
  template unfold(k: int, value: float64) =
    samples[3*length - 1 - k] = -value
    if k < length: samples[3*length + k] = -value
    else: samples[k - length] = value
  for i in 0 ..< length:
    let pair = work[i] * plan.rotation[i]
    unfold(2*i, pair.re)
    unfold(half - 1 - 2*i, pair.im)

proc initWindow*(length: int): seq[float64] =
  ## Returns the rising half of the Vorbis overlap window.
  result.setLen(length)
  for i in 0 ..< length:
    let a = sin((PI * 0.5 / float64(length)) * (float64(i) + 0.5))
    result[i] = sin(PI * 0.5 * a * a)
