## Theora fixed-point inverse DCT.
## Derived from libtheora, copyright (C) 2002-2009 Xiph.org Foundation.
## Redistribution terms are in licenses/theora.txt.

import simd
when useX86Simd: import transformsavx2

type DctBlock* = array[64, int16]

proc narrow*(v: int): int16 {.inline.} =
  ## Retains the low signed 16 bits at the codec's specified wrap points.
  cast[int16](uint16(v and 65535))

{.push boundChecks: not defined(release), overflowChecks: not defined(release).}
proc transform(input: DctBlock, output: var DctBlock, row: range[0..7],
    terms: static int) {.inline.} =
  ## Transforms one row into a column with the normative fixed-point rotations.
  # Each table index stays inside the fixed 8x8 block. Rotation products
  # use signed 16-bit inputs and cosine constants smaller than 65536.
  const Cosine = [0'i32, 64277, 60547, 54491, 46341, 36410, 25080, 12785]
  template x(i: static int): int32 =
    when i < terms: int32(input[row * 8 + i])
    else: 0'i32
  template mul(k, v: untyped): int32 = (Cosine[k] * int32(v)) shr 16
  var
    a = mul(4, int(narrow(x(0) + x(4))))
    b = mul(4, int(narrow(x(0) - x(4))))
    c = mul(6, x(2)) - mul(2, x(6))
    d = mul(2, x(2)) + mul(6, x(6))
    e = mul(7, x(1)) - mul(1, x(7))
    f = mul(3, x(5)) - mul(5, x(3))
    g = mul(5, x(5)) + mul(3, x(3))
    h = mul(1, x(1)) + mul(7, x(7))
  (e, f) = (e + f, mul(4, int(narrow(e - f))))
  (h, g) = (h + g, mul(4, int(narrow(h - g))))
  (a, d) = (a + d, a - d)
  (b, c) = (b + c, b - c)
  (g, f) = (g + f, g - f)
  let values = [a+h, b+g, c+f, d+e, d-e, c-f, b-g, a-h]
  for i, value in values:
    output[i * 8 + row] = narrow(value)

proc inverseDct*(coefficients: var DctBlock, last = 64) =
  ## Applies the two-dimensional transform and its final scale adjustment.
  var temp: DctBlock
  # A final token at or before zigzag position 3 or 10 confines nonzero
  # coefficients to a triangle in the top-left 2x2 or 4x4 respectively.
  if last <= 3:
    transform(coefficients, temp, 0, 2)
    transform(coefficients, temp, 1, 1)
    for row in 0 ..< 8: transform(temp, coefficients, row, 2)
  elif last <= 10:
    transform(coefficients, temp, 0, 4)
    transform(coefficients, temp, 1, 3)
    transform(coefficients, temp, 2, 2)
    transform(coefficients, temp, 3, 1)
    for row in 0 ..< 8: transform(temp, coefficients, row, 4)
  else:
    when useX86Simd:
      if hasAvx2:
        denseDctAvx2(coefficients)
        return
    for row in 0 ..< 8: transform(coefficients, temp, row, 8)
    for row in 0 ..< 8: transform(temp, coefficients, row, 8)
  for value in coefficients.mitems: value = int16((int32(value) + 8) shr 4)
{.pop.}
