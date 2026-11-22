## Derived from libvorbis, copyright (c) 2002-2020 Xiph.org Foundation.
## Redistribution terms are in licenses/vorbis.txt.
## Vorbis I packed codebooks and vector lookup.
import std/math
import bitstreams

type Book* = object
  dimension*, entries*, lookup*: int
  nodes: seq[array[2, int32]]
  minimum, delta: float32
  steps: seq[uint16]
  cumulative: bool

proc unpackFloat(r: var BitReader): float32 =
  ## Decodes the Vorbis signed mantissa and biased binary exponent.
  let value = r.readUnsigned(32)
  let exponent = clamp(int((value shr 21) and 1023) - 788, -63, 63)
  result = float32(float64(value and 0x1fffff) * pow(2.0, float64(exponent)))
  if (value shr 31) != 0:
    result = -result

proc quantCount(entries, dimension: int): int =
  ## Finds the largest integer whose dimension-th power fits in entries.
  var lo = 1
  var hi = entries
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    var product = 1
    for i in 0 ..< dimension:
      if product > entries div mid:
        product = entries + 1
        break
      product *= mid
    if product <= entries: lo = mid
    else: hi = mid - 1
  lo

proc readBook*(r: var BitReader, budget: var int): Book =
  ## Builds the prefix tree in Vorbis entry order and retains packed vectors.
  if r.read(24) != 0x564342:
    invalid("Invalid Vorbis codebook sync.")
  result.dimension = r.read(16)
  result.entries = r.read(24)
  if result.entries < 1 or result.dimension < 1 or result.entries > budget:
    invalid("Invalid or oversized Vorbis codebook.")
  budget -= result.entries
  let ordered = r.flag()
  let sparse = not ordered and r.flag()
  var
    markers: array[33, uint64]
    length, left, used: int
    coverage: uint64
  result.nodes.add([0'i32, 0])
  if ordered:
    length = r.read(5)
  for entry in 0 ..< result.entries:
    if ordered:
      while left == 0:
        inc length
        if length > 32:
          invalid("Invalid ordered Vorbis code lengths.")
        left = r.read(ilog(result.entries - entry))
        if left > result.entries - entry:
          invalid("Invalid Vorbis code length count.")
      dec left
    else:
      if sparse and not r.flag():
        continue
      length = r.read(5) + 1
    inc used
    coverage += 1'u64 shl (32 - length)
    var word = markers[length]
    if word >= (1'u64 shl length):
      invalid("Oversubscribed Vorbis codebook.")
    var node = 0
    for bit in countdown(length - 1, 0):
      let side = int((word shr bit) and 1)
      if bit == 0:
        result.nodes[node][side] = int32(-entry - 1)
      else:
        if result.nodes[node][side] == 0:
          result.nodes[node][side] = int32(result.nodes.len)
          result.nodes.add([0'i32, 0])
        node = int(result.nodes[node][side])
    for j in countdown(length, 1):
      if (markers[j] and 1) != 0 and j > 1:
        markers[j] = markers[j - 1] shl 1
        break
      inc markers[j]
    for j in length + 1 .. 32:
      if (markers[j] shr 1) != word: break
      word = markers[j]
      markers[j] = markers[j - 1] shl 1
  if used != 0 and coverage != 1'u64 shl 32 and
      not (used == 1 and coverage == 1'u64 shl 31):
    invalid("Incomplete Vorbis codebook.")
  result.lookup = r.read(4)
  if result.lookup > 2:
    invalid("Invalid Vorbis lookup type.")
  if result.lookup != 0:
    result.minimum = r.unpackFloat()
    result.delta = r.unpackFloat()
    let bits = r.read(4) + 1
    result.cumulative = r.flag()
    let count = if result.lookup == 1: quantCount(result.entries, result.dimension)
                else: int64(result.entries) * result.dimension
    if count > budget:
      invalid("Oversized Vorbis vector lookup.")
    budget -= int(count)
    result.steps.setLen(int(count))
    for value in result.steps.mitems:
      value = uint16(r.read(bits))

proc scalar*(r: var BitReader, book: Book): int =
  ## Walks a codeword and returns the original entry number.
  var node = 0
  while true:
    node = int(book.nodes[node][r.readBit(false)])
    if node < 0: return -1 - node
    if node == 0: invalid("Invalid Vorbis codeword.")

iterator vector*(book: Book, entry: int): float64 =
  ## Expands one selected vector without allocating a dense lookup table.
  var index = entry
  var last = 0.0'f32
  for i in 0 ..< book.dimension:
    let step = if book.lookup == 1: index mod book.steps.len
               else: entry * book.dimension + i
    let value = float32(float64(book.minimum) +
      float64(book.delta) * float64(book.steps[step]) + float64(last))
    if book.cumulative: last = value
    if book.lookup == 1: index = index div book.steps.len
    yield float64(value)
