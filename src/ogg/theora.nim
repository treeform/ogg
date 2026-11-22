## Sequential Theora frame reconstruction.
## Derived from libtheora, copyright (C) 2002-2009 Xiph.org Foundation.
## Redistribution terms are in licenses/theora.txt.
import std/math
import profiles, simd
when useX86Simd: import kernelsavx2
import bitstreams, common, packets, theoradct, theoraframes, theorasetup

type
  Picture = ref array[3, Plane]
  Theora* = object
    setup*: TheoraSetup
    layout: Layout
    previous, golden: Picture
    frames: int64

proc header*(v: var Theora, packet: Packet) =
  ## Initializes the geometry once the three headers have been consumed.
  v.setup.header(packet)
  if packet.number == 2:
    v.layout = initLayout(v.setup)

proc blank(l: Layout): Picture =
  ## Allocates tightly packed planes using the full coded dimensions.
  new(result)
  for p in 0 .. 2:
    let w = l.widths[p] * 8
    let h = l.heights[p] * 8
    result[p] = Plane(width: w, height: h, data: newSeq[uint8](w * h))

proc predictor(f: FrameData, index, x, y, width, previous: int): int =
  ## Predicts DC from already decoded blocks with the same reference picture.
  let source = f.blocks[index].source
  if y == 0: return previous
  var neighbors: array[4, int]
  var mask = 0
  for k, offset in [-1, -width - 1, -width, -width + 1]:
    if (k <= 1 and x == 0) or (k == 3 and x + 1 == width): continue
    let n = index + offset
    if f.blocks[n].coded and f.blocks[n].source == source:
      mask = mask or (1 shl k)
      neighbors[k] = int(f.blocks[n].coeff[0])
  let (a,b,c,d) = (neighbors[0], neighbors[1], neighbors[2], neighbors[3])
  case mask
  of 1, 3: a
  of 2: b
  of 4, 6, 12: c
  of 5: (a+c) div 2
  of 8: d
  of 9, 11, 13: (75*a + 53*d) div 128
  of 10: (b+d) div 2
  of 14: (3*(b+d) + 10*c) div 16
  of 7, 15:
    let p = (29*(a+c) - 26*b) div 32
    if abs(p-c) > 128: c
    elif abs(p-a) > 128: a
    elif abs(p-b) > 128: b
    else: p
  else: previous

proc residual(frag: Fragment, dc: int, ac: QuantTable): DctBlock =
  ## Dequantizes the coefficients and selects the normative DC shortcut.
  let value = int(frag.coeff[0]) * dc
  if frag.last < 2:
    let level = narrow((value + 15) shr 5)
    for sample in result.mitems: sample = level
  else:
    result[0] = narrow(value)
    for i in 1 ..< 64: result[i] = narrow(int(frag.coeff[i]) * int(ac[i]))
    result.inverseDct(frag.last)

proc pixel(plane: Plane, x, y: int): int {.inline.} =
  ## Extends the reference picture by replicating its edges.
  int(plane.data[clamp(y, 0, plane.height - 1) * plane.width +
    clamp(x, 0, plane.width - 1)])

type PixelRow = array[8, uint8]

proc blockRow(plane: Plane, offset: int): ptr PixelRow {.inline.} =
  ## Views eight contiguous pixels of a coded block or interior predictor.
  assert offset >= 0 and offset <= plane.data.len - 8
  cast[ptr PixelRow](unsafeAddr plane.data[offset])

proc reconstruct(v: Theora, f: var FrameData, dest: Picture, p: int) {.measure.} =
  ## Restores one plane in bottom-up raster order for DC prediction.
  let
    w = v.layout.widths[p]
    h = v.layout.heights[p]
    dx = if p == 0: 2 else: 2 shl v.layout.sx
    dy = if p == 0: 2 else: 2 shl v.layout.sy
  var previousDc: array[3, int]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let index = v.layout.starts[p] + y * w + x
      template frag: untyped = f.blocks[index]
      let bottom = dest[p].height - 1 - 8*y
      if not frag.coded:
        for row in 0 ..< 8:
          let offset = (bottom - row) * dest[p].width + 8*x
          copyMem(addr dest[p].data[offset], addr v.previous[p].data[offset], 8)
        continue
      let source = frag.source
      let dc = f.predictor(index, x, y, w, previousDc[source])
      frag.coeff[0] = narrow(dc + int(frag.coeff[0]))
      previousDc[source] = int(frag.coeff[0])
      let table = p + 3 * int(source != 1)
      let samples = frag.residual(int(v.setup.quant[f.qis[0]][table][0]),
        v.setup.quant[f.qis[frag.qi]][table])
      let refPic = if source == 2: v.golden else: v.previous
      let mx = frag.mv.x div dx
      let my = -(frag.mv.y div dy)
      let mx2 = mx + cmp(frag.mv.x mod dx, 0)
      let my2 = my - cmp(frag.mv.y mod dy, 0)
      let left = 8*x
      let interior = left + min(mx, mx2) >= 0 and
        left + max(mx, mx2) + 7 < dest[p].width and
        bottom + min(my, my2) - 7 >= 0 and
        bottom + max(my, my2) < dest[p].height
      when useX86Simd:
        if hasAvx2:
          let stride = dest[p].width
          let offset = bottom * stride + left
          if source == 1:
            writeBlockAvx2(dest[p].data, offset, stride, samples, [], 0, 0)
            continue
          if interior:
            writeBlockAvx2(dest[p].data, offset, stride, samples, refPic[p].data,
              offset + my * stride + mx, offset + my2 * stride + mx2)
            continue
      for row in 0 ..< 8:
        let py = bottom - row
        let offset = py * dest[p].width + left
        let output = dest[p].blockRow(offset)
        let residuals = cast[ptr array[8, int16]](unsafeAddr samples[row*8])
        template store(col, prediction: int) =
          output[col] = uint8(clamp(prediction + int(residuals[col]), 0, 255))
        if source == 1:
          for col in 0 ..< 8: store(col, 128)
        elif interior:
          let a = refPic[p].blockRow(offset + my * dest[p].width + mx)
          if mx == mx2 and my == my2:
            for col in 0 ..< 8: store(col, int(a[col]))
          else:
            let b = refPic[p].blockRow(offset + my2 * dest[p].width + mx2)
            for col in 0 ..< 8:
              store(col, (int(a[col]) + int(b[col])) shr 1)
        else:
          for col in 0 ..< 8:
            let px = left + col
            let a = refPic[p].pixel(px + mx, py + my)
            let b = refPic[p].pixel(px + mx2, py + my2)
            store(col, (a + b) div 2)

# filter only visits internal block boundaries, so all four taps and
# all eight pixels along each edge lie within the coded plane.
{.push boundChecks: not defined(release), overflowChecks: not defined(release).}
proc edge(plane: var Plane, offset, across, along, limit: int) {.inline.} =
  ## Applies the four-tap loop filter at one eight-pixel block boundary.
  for i in 0 ..< 8:
    let j = offset + i * along
    let a = int(plane.data[j - across])
    let b = int(plane.data[j])
    let raw = (int(plane.data[j - 2*across]) - int(plane.data[j + across]) +
      3*(b - a) + 4) shr 3
    let adjustment = sgn(raw) * max(0, min(abs(raw), 2*limit - abs(raw)))
    plane.data[j - across] = uint8(clamp(a + adjustment, 0, 255))
    plane.data[j] = uint8(clamp(b - adjustment, 0, 255))
{.pop.}

proc filter(l: Layout, f: FrameData, dest: Picture, p, limit: int) {.measure.} =
  ## Filters each boundary adjacent to a coded block exactly once.
  if limit == 0: return
  let width = l.widths[p]
  let height = l.heights[p]
  let stride = -dest[p].width
  for y in 0 ..< height:
    for x in 0 ..< width:
      let i = l.starts[p] + y * width + x
      if f.blocks[i].coded:
        let offset = (dest[p].height - 1 - 8*y) * dest[p].width + 8*x
        if x > 0: dest[p].edge(offset, 1, stride, limit)
        if y > 0: dest[p].edge(offset, stride, 1, limit)
        if x + 1 < width and not f.blocks[i+1].coded:
          dest[p].edge(offset + 8, 1, stride, limit)
        if y + 1 < height and not f.blocks[i+width].coded:
          dest[p].edge(offset + 8*stride, stride, 1, limit)

proc decode*(v: var Theora, packet: Packet): VideoFrame =
  ## Decodes an intra, predicted, or duplicate picture and retains references.
  var f: FrameData
  if packet.data.len > 0:
    var r = BitReader(data: packet.data, msb: true)
    f = r.unpack(v.setup, v.layout)
  if v.previous == nil and not f.intra:
    v.previous = blank(v.layout)
    for plane in v.previous[].mitems:
      for pixel in plane.data.mitems: pixel = 128
    v.golden = v.previous
  if f.blocks.len > 0:
    for qi in f.qis: v.setup.prepareQuant(qi)
    let dest = blank(v.layout)
    for p in 0 .. 2:
      v.reconstruct(f, dest, p)
      v.layout.filter(f, dest, p, v.setup.filter[f.qis[0]])
    v.previous = dest
    if f.intra: v.golden = dest
  result = VideoFrame(planes: v.previous[], info: v.setup.info,
    time: float64(v.frames) * float64(v.setup.info.fpsDenominator) /
      float64(v.setup.info.fpsNumerator))
  inc v.frames
