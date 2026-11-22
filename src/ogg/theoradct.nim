## Theora fixed-point inverse DCT.
## Derived from libtheora, copyright (C) 2002-2009 Xiph.org Foundation.
## Redistribution terms are in licenses/theora.txt.

type DctBlock* = array[64, int16]

proc narrow*(v: int): int16 {.inline.} =
  ## Retains the low signed 16 bits at the codec's specified wrap points.
  cast[int16](uint16(v and 65535))

{.push boundChecks: not defined(release), overflowChecks: not defined(release).}
proc transform(input: DctBlock, output: var DctBlock, row: range[0..7]) =
  ## Transforms one row into a column with the normative fixed-point rotations.
  # Each table index stays inside the fixed 8x8 block. Rotation products
  # use signed 16-bit inputs and cosine constants smaller than 65536.
  const Cosine = [0, 64277, 60547, 54491, 46341, 36410, 25080, 12785]
  template x(i: int): int = int(input[row * 8 + i])
  template mul(k, v: int): int = (Cosine[k] * (v)) shr 16
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
{.pop.}

proc inverseDct*(coefficients: var DctBlock) =
  ## Applies the two-dimensional transform and its final scale adjustment.
  var temp: DctBlock
  for row in 0 ..< 8: transform(coefficients, temp, row)
  for row in 0 ..< 8: transform(temp, coefficients, row)
  for value in coefficients.mitems: value = int16((int(value) + 8) shr 4)
