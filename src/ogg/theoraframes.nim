## Theora coded-block order, prediction modes and DCT token unpacking.
## Derived from libtheora, copyright (C) 2002-2009 Xiph.org Foundation.
## Redistribution terms are in licenses/theora.txt.
import bitstreams, common, theoradct, theorasetup

type
  Motion* = tuple[x, y: int]
  Fragment* = object
    coded*: bool
    source*, qi*, last*, plane*: int
    mv*: Motion
    coeff*: DctBlock
  Layout* = object
    widths*, heights*, starts*: array[3, int]
    count*: int
    sx*, sy*: int
    superblocks: seq[array[16, int]]
    macroblocks: seq[tuple[x, y: int]]
  FrameData* = object
    blocks*: seq[Fragment]
    coded: seq[int]
    qis*: seq[int]
    intra*: bool

const
  Scan = [(0,0),(1,0),(1,1),(0,1), (0,2),(0,3),(1,3),(1,2),
          (2,2),(2,3),(3,3),(3,2), (3,1),(2,1),(2,0),(3,0)]
  Zigzag = [0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,
    40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,
    15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
  Alphabets = [[3,4,2,0,1,5,6,7], [3,4,0,2,1,5,6,7], [3,2,4,0,1,5,6,7],
    [3,2,0,4,1,5,6,7], [0,3,4,2,1,5,6,7], [0,5,3,4,2,1,6,7],
    [0,1,2,3,4,5,6,7]]

proc initLayout*(s: TheoraSetup): Layout =
  ## Maps the bitstream's bottom-up Hilbert traversal onto planar block grids.
  result.sx = int(s.info.pixelFormat != Yuv444)
  result.sy = int(s.info.pixelFormat == Yuv420)
  for p in 0 .. 2:
    let w = (s.width div 8) shr (if p == 0: 0 else: result.sx)
    let h = (s.height div 8) shr (if p == 0: 0 else: result.sy)
    result.widths[p] = w
    result.heights[p] = h
    result.starts[p] = result.count
    for y in countup(0, h - 1, 4):
      for x in countup(0, w - 1, 4):
        var sb: array[16, int]
        for i, offset in Scan:
          let bx = x + offset[0]
          let by = y + offset[1]
          sb[i] = if bx < w and by < h: result.count + by * w + bx else: -1
        result.superblocks.add(sb)
        if p == 0:
          for (dx, dy) in [(0,0), (0,2), (2,2), (2,0)]:
            if x + dx < w and y + dy < h:
              result.macroblocks.add((x + dx, y + dy))
    result.count += w * h

proc unary(r: var BitReader, limit: int): int =
  ## Counts leading one bits in a bounded prefix.
  while result < limit and r.flag(): inc result

proc flags(r: var BitReader, count: int, small = false): seq[bool] =
  ## Expands alternating superblock or block runs.
  if count == 0: return
  result.setLen(count)
  var value = r.flag()
  var pos = 0
  while pos < count:
    let n = if small:
      let prefix = r.unary(5)
      [1,3,5,7,11,15][prefix] + r.read([1,1,1,2,2,4][prefix])
    else:
      let prefix = r.unary(6)
      [1,2,4,6,10,18,34][prefix] + r.read([0,1,1,2,3,4,12][prefix])

    if n > count - pos: invalid("Excess Theora flag run.")
    for i in pos ..< pos + n: result[i] = value
    pos += n
    if n == 4129 and pos < count: value = r.flag()
    else: value = not value

proc codedFlags(r: var BitReader, l: Layout, f: var FrameData) =
  ## Selects coded blocks in superblock order, across all three planes.
  var partial, full, bits: seq[bool]
  if not f.intra:
    partial = r.flags(l.superblocks.len)
    var fullCount, bitCount: int
    for i, sb in l.superblocks:
      if partial[i]:
        for index in sb:
          if index >= 0: inc bitCount
      else: inc fullCount
    full = r.flags(fullCount)
    bits = r.flags(bitCount, true)
  var bit, nonPartial: int
  for i, sb in l.superblocks:
    for index in sb:
      if index < 0: continue
      let coded = if f.intra: true
                  elif not partial[i]: full[nonPartial]
                  else: bits[bit]
      if not f.intra and partial[i]: inc bit
      if coded:
        f.blocks[index].coded = true
        f.blocks[index].source = int(f.intra)
        f.coded.add(index)
    if not f.intra and not partial[i]: inc nonPartial

proc component(r: var BitReader, fixed: bool): int =
  ## Reads one signed half-pixel motion-vector component.
  if fixed:
    result = r.read(5)
  else:
    let code = r.read(3)
    case code
    of 0: return 0
    of 1: return 1
    of 2: return -1
    of 3, 4: result = code - 1
    else: result = (1 shl (code - 3)) + r.read(code - 3)
  if r.flag(): result = -result

proc motion(r: var BitReader, fixed: bool): Motion =
  ## Reads horizontal and vertical motion in bitstream order.
  result.x = r.component(fixed)
  result.y = r.component(fixed)

proc average(value, count: int): int =
  ## Rounds a signed chroma vector to the nearest integer, ties away from zero.
  (value + (if value < 0: -(count div 2) else: count div 2)) div count

proc modes(r: var BitReader, l: Layout, f: var FrameData) =
  ## Decodes macroblock modes and distributes their motion to coded fragments.
  let scheme = r.read(3)
  var alphabet: array[8, int]
  if scheme == 0:
    for mode in 0 .. 7: alphabet[r.read(3)] = mode
  else: alphabet = Alphabets[scheme - 1]
  var modes = newSeq[int](l.macroblocks.len)
  for i, mb in l.macroblocks:
    let a = mb.y * l.widths[0] + mb.x
    if f.blocks[a].coded or f.blocks[a + 1].coded or
        f.blocks[a + l.widths[0]].coded or f.blocks[a + l.widths[0] + 1].coded:
      modes[i] = alphabet[if scheme == 7: r.read(3) else: r.unary(7)]
  let fixed = r.flag()
  var last, prior: Motion
  for i, mb in l.macroblocks:
    let mode = modes[i]
    var mv: Motion
    var four: array[4, Motion]
    case mode
    of 2:
      prior = last
      last = r.motion(fixed)
      mv = last
    of 3: mv = last
    of 4:
      swap(last, prior)
      mv = last
    of 6: mv = r.motion(fixed)
    of 7:
      prior = last
      for j in 0 .. 3:
        let index = (mb.y + j div 2) * l.widths[0] + mb.x + j mod 2
        if f.blocks[index].coded:
          last = r.motion(fixed)
          four[j] = last
    else: discard
    for p in 0 .. 2:
      let sx = if p == 0: 0 else: l.sx
      let sy = if p == 0: 0 else: l.sy
      for y in 0 ..< (2 shr sy):
        for x in 0 ..< (2 shr sx):
          let index = l.starts[p] + ((mb.y shr sy) + y) * l.widths[p] + (mb.x shr sx) + x
          if f.blocks[index].coded:
            f.blocks[index].source = if mode == 1: 1 elif mode in 5..6: 2 else: 0
            if mode == 7:
              var dx, dy: int
              let count = 1 shl (sx + sy)
              for yy in 0 ..< 1 shl sy:
                for xx in 0 ..< 1 shl sx:
                  let v = four[2 * ((y shl sy) + yy) + (x shl sx) + xx]
                  dx += v.x
                  dy += v.y
              mv = (average(dx, count), average(dy, count))
            f.blocks[index].mv = mv

proc quantizers(r: var BitReader, f: var FrameData) =
  ## Selects one of the frame's quantizers for each coded block.
  if f.qis.len == 1: return
  let first = r.flags(f.coded.len)
  var count = 0
  for flag in first:
    if flag: inc count
  let second = if f.qis.len == 3: r.flags(count) else: @[]
  var j = 0
  for i, index in f.coded:
    if first[i]:
      f.blocks[index].qi = 1 + int(second.len > 0 and second[j])
      inc j

proc coefficients(r: var BitReader, s: TheoraSetup, f: var FrameData) =
  ## Distributes coefficient-major tokens over the coded blocks.
  var
    next = newSeq[int](f.coded.len)
    tables: array[2, int]
    eobs = 0
  for z in 0 ..< 64:
    if z <= 1:
      for table in tables.mitems: table = r.read(4)
    let group = if z == 0: 0 elif z < 6: 1 elif z < 15: 2 elif z < 28: 3 else: 4
    for i, index in f.coded:
      if next[i] != z: continue
      template frag: untyped = f.blocks[index]
      frag.last = z
      if eobs > 0:
        dec eobs
        next[i] = 64
        continue
      let token = r.token(s, group * 16 + tables[int(frag.plane > 0)])
      var zeros, value: int
      case token
      of 0 .. 6:
        let run = [1,2,3,4,8,16,0][token] + r.read([0,0,0,2,3,4,12][token])
        eobs = if run == 0: high(int) else: run - 1
        next[i] = 64
        continue
      of 7, 8:
        zeros = r.read(if token == 7: 3 else: 6)
      of 9 .. 12: value = [1, -1, 2, -2][token - 9]
      else:
        let negative = r.flag()
        case token
        of 13 .. 16: value = token - 10
        of 17 .. 22:
          value = [7,9,13,21,37,69][token - 17] + r.read([1,2,3,4,5,9][token - 17])
        of 23 .. 27:
          zeros = token - 22
          value = 1
        of 28, 29:
          zeros = if token == 28: 6 + r.read(2) else: 10 + r.read(3)
          value = 1
        of 30, 31:
          value = 2 + r.read(1)
          zeros = if token == 30: 1 else: 2 + r.read(1)
        else: invalid("Invalid Theora coefficient token.")
        if negative: value = -value
      let pos = z + zeros
      if pos >= 64: invalid("Theora coefficient run exceeds block.")
      frag.coeff[Zigzag[pos]] = int16(value)
      next[i] = pos + 1

proc unpack*(r: var BitReader, s: TheoraSetup, l: Layout): FrameData =
  ## Reads one nonempty frame packet through its final residual token.
  if r.flag(): invalid("Expected Theora frame packet.")
  result.intra = not r.flag()
  result.qis.add(r.read(6))
  while result.qis.len < 3 and r.flag(): result.qis.add(r.read(6))
  if result.intra and r.read(3) != 0: invalid("Invalid Theora keyframe flags.")
  result.blocks.setLen(l.count)
  for p in 1 .. 2:
    for i in l.starts[p] ..< l.starts[p] + l.widths[p] * l.heights[p]:
      result.blocks[i].plane = p
  r.codedFlags(l, result)
  if result.coded.len > 0:
    if not result.intra:
      r.modes(l, result)
    r.quantizers(result)
    r.coefficients(s, result)
