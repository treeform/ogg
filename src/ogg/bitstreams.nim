import common

type
  EndOfPacket* = object of OggError

  BitReader* = object
    data*: string
    pos*: int
    bit: int
    msb*: bool

proc invalid*(reason: string) {.noreturn.} =
  ## Reports an invalid codec packet at the public error boundary.
  raise newException(OggError, reason)

proc readUnsigned*(r: var BitReader, count: int): uint32 =
  ## Reads up to 32 bits, advancing only within the current packet.
  var remaining = count
  while remaining > 0:
    if r.pos >= r.data.len:
      raise newException(EndOfPacket, "Truncated codec packet.")
    let
      take = min(8 - r.bit, remaining)
      shift = if r.msb: 8 - take - r.bit else: r.bit
      bits = (uint32(r.data[r.pos]) shr shift) and ((1'u32 shl take) - 1)
    if r.msb:
      result = (result shl take) or bits
    else:
      result = result or (bits shl (count - remaining))
    remaining -= take
    r.bit += take
    if r.bit == 8:
      r.bit = 0
      inc r.pos

proc read*(r: var BitReader, count: int): int =
  ## Reads a nonnegative field that must fit in a native integer.
  let value = r.readUnsigned(count)
  when sizeof(int) == 4:
    if value > high(int).uint32:
      invalid("Codec field exceeds the supported range.")
  int(value)

proc flag*(r: var BitReader): bool =
  ## Reads a single flag.
  r.read(1) != 0

proc ilog*(value: int): int =
  ## Counts the bits required to represent a nonnegative integer.
  var v = value
  while v > 0:
    inc result
    v = v shr 1

proc comments*(data: string, framing: bool) =
  ## Validates the length-prefixed vendor string and comment list.
  var r = BitReader(data: data, pos: 7)
  proc skipString(r: var BitReader) =
    let n = r.read(32)
    if n > r.data.len - r.pos:
      invalid("Truncated codec comment.")
    r.pos += n
  r.skipString()
  let count = r.read(32)
  if count > (data.len - r.pos) div 4:
    invalid("Invalid codec comment count.")
  for i in 0 ..< count:
    r.skipString()
  if framing and not r.flag():
    invalid("Missing Vorbis comment framing bit.")

