## Theora headers and quantization tables.
## Derived from libtheora, copyright (C) 2002-2009 Xiph.org Foundation.
## Redistribution terms are in licenses/theora.txt.
import bitstreams, common, packets
import profiles

type
  HuffTree = object
    root, count: int
    branches: array[31, array[2, int8]]
  QuantTable* = array[64, uint16]
  QuantRange = object
    start, span, left, right: int
  TheoraSetup* = object
    info*: VideoInfo
    width*, height*: int
    filter*: array[64, int]
    quant*: array[64, ref array[6, QuantTable]]
    ac, dc: array[64, int]
    bases: seq[array[64, uint8]]
    ranges: array[6, seq[QuantRange]]
    trees: array[80, HuffTree]

proc readTree(r: var BitReader, tree: var HuffTree, depth: int): int =
  ## Reads a preorder Huffman tree, storing terminals as negative indices.
  if r.hasWindow:
    let bits = r.peekByte(true)
    if bits >= 128:
      r.advance(6)
      return -1 - ((bits shr 2) and 31)
    r.advance(1)
  elif r.flag():
    return -1 - r.read(5)
  if tree.count >= tree.branches.len or depth >= 32:
    invalid("Oversized Theora Huffman tree.")
  result = tree.count
  inc tree.count
  for i in 0 .. 1:
    let child = r.readTree(tree, depth + 1)
    tree.branches[result][i] = int8(child)

proc readTrees(r: var BitReader, s: var TheoraSetup) {.measure.} =
  ## Reads the 80 token trees in setup order.
  for tree in s.trees.mitems: tree.root = r.readTree(tree, 0)

proc token*(r: var BitReader, s: TheoraSetup, index: int): int =
  ## Decodes a DCT token from the selected table.
  let tree = addr s.trees[index]
  var node = tree.root
  while node >= 0 and r.hasWindow:
    let bits = r.peekByte(true)
    var used = 0
    while node >= 0 and used < 8:
      inc used
      node = int(tree.branches[node][(bits shr (8 - used)) and 1])
    r.advance(used)
  while node >= 0:
    node = int(tree.branches[node][r.readBit(true)])
  -1 - node

proc quantization(r: var BitReader, s: var TheoraSetup) {.measure.} =
  ## Reads and validates the scaling factors, base matrices and ranges.
  let filterBits = r.read(3)
  for value in s.filter.mitems: value = r.read(filterBits)
  let acBits = r.read(4) + 1
  for value in s.ac.mitems: value = r.read(acBits)
  let dcBits = r.read(4) + 1
  for value in s.dc.mitems: value = r.read(dcBits)
  s.bases.setLen(r.read(9) + 1)
  for base in s.bases.mitems:
    for value in base.mitems: value = uint8(r.read(8))
  let indexBits = ilog(s.bases.high)
  for table in 0 ..< 6:
    if table != 0 and not r.flag():
      let source = if table >= 3 and r.flag(): table - 3 else: table - 1
      s.ranges[table] = s.ranges[source]
    else:
      var start = 0
      var left = r.read(indexBits)
      if left >= s.bases.len: invalid("Invalid Theora base matrix index.")
      while start < 63:
        let span = r.read(ilog(62 - start)) + 1
        let right = r.read(indexBits)
        if right >= s.bases.len or start + span > 63:
          invalid("Invalid Theora quantization range.")
        s.ranges[table].add(QuantRange(start: start, span: span, left: left,
          right: right))
        start += span
        left = right

proc prepareQuant*(s: var TheoraSetup, qi: int) =
  ## Expands each signaled quality index once, on its first frame.
  if s.quant[qi] != nil: return
  new(s.quant[qi])
  for table in 0 ..< 6:
    for r in s.ranges[table]:
      let t = qi - r.start
      if t > r.span: continue
      for j in 0 ..< 64:
        let blend = (r.span - t) * int(s.bases[r.left][j]) +
          t * int(s.bases[r.right][j])
        let value = (2 * blend + r.span) div (2 * r.span)
        let scale = if j == 0: s.dc[qi] else: s.ac[qi]
        let minimum = (if j == 0: 16 else: 8) shl int(table >= 3)
        s.quant[qi][table][j] =
          uint16(clamp(4 * (value * scale div 100), minimum, 4096))
      break

proc header*(s: var TheoraSetup, packet: Packet) =
  ## Reads identification, comments, or setup from one checked Ogg packet.
  if packet.number notin 0'i64 .. 2 or packet.data.len < 7 or
      ord(packet.data[0]) != 128 + packet.number or packet.data[1..6] != "theora":
    invalid("Invalid Theora header.")
  var r = BitReader(data: packet.data, pos: 7, msb: true)
  case packet.number
  of 0:
    let major = r.read(8)
    let minor = r.read(8)
    discard r.read(8)
    if major > 3 or (major == 3 and minor > 2):
      invalid("Unsupported Theora version.")
    s.width = r.read(16) * 16
    s.height = r.read(16) * 16
    s.info.width = r.read(24)
    s.info.height = r.read(24)
    s.info.offsetX = r.read(8)
    s.info.offsetY = s.height - s.info.height - r.read(8)
    s.info.fpsNumerator = r.readUnsigned(32)
    s.info.fpsDenominator = r.readUnsigned(32)
    if s.width notin 16 .. 4096 or s.height notin 16 .. 4096 or
        s.info.width == 0 or s.info.height == 0 or s.info.offsetY < 0 or
        s.info.width + s.info.offsetX > s.width or s.info.fpsNumerator == 0 or
        s.info.fpsDenominator == 0:
      invalid("Invalid Theora dimensions or frame rate.")
    for bits in [24, 24, 8, 24, 6, 5]: discard r.read(bits)
    case r.read(2)
    of 0: s.info.pixelFormat = Yuv420
    of 2: s.info.pixelFormat = Yuv422
    of 3: s.info.pixelFormat = Yuv444
    else: invalid("Reserved Theora pixel format.")
    if r.read(3) != 0: invalid("Invalid Theora header flags.")
  of 1: comments(packet.data, false)
  else:
    r.quantization(s)
    readTrees(r, s)
