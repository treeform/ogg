## Sequential Ogg page validation and logical packet assembly.
import common

type
  Packet* = object
    data*: string
    stream*: int
    number*, granule*: int64
    eos*: bool

  Stream = object
    serial, sequence: uint32
    number: int64
    partial: string
    eos: bool

  PacketReader* = object
    data*: string
    streams: array[2, Stream]
    count*: int
    body*: bool
    active, position, lace, laceEnd, lastComplete, payload: int
    granule: int64

const CrcTable = block:
  var table: array[256, uint32]
  for index in 0 .. 255:
    var value = uint32(index) shl 24
    for bit in 0 ..< 8:
      let top = value shr 31
      value = (value shl 1) xor (top * 0x04c11db7'u32)
    table[index] = value
  table

proc little32(data: string, offset: int): uint32 =
  ## Reads an unaligned little-endian value from a checked page header.
  for i in 0 ..< 4:
    result = result or (uint32(data[offset + i]) shl (8 * i))

proc nextPage(r: var PacketReader): bool {.raises: [OggError].} =
  ## Validates the entire next page before emitting any of its packets.
  let p = r.position
  if p == r.data.len:
    for i in 0 ..< r.count:
      if not r.streams[i].eos:
        raise newException(OggError, "Missing Ogg end-of-stream page.")
    return false
  if r.data.len - p < 27 or r.data[p ..< p + 4] != "OggS" or
      r.data[p + 4] != '\0':
    raise newException(OggError, "Invalid or truncated Ogg page header.")
  let flags = ord(r.data[p + 5])
  if flags > 7:
    raise newException(OggError, "Invalid Ogg page flags.")
  r.lace = p + 27
  let segments = ord(r.data[p + 26])
  if segments > r.data.len - r.lace:
    raise newException(OggError, "Truncated Ogg lacing table.")
  r.laceEnd = r.lace + segments
  r.payload = r.laceEnd
  r.lastComplete = -1
  var length = 0
  for i in r.lace ..< r.laceEnd:
    let size = ord(r.data[i])
    length += size
    if size < 255:
      r.lastComplete = i
  if length > r.data.len - r.payload:
    raise newException(OggError, "Truncated Ogg page payload.")
  r.position = r.payload + length
  var crc: uint32
  for i in p ..< r.position:
    let value = if i - p in 22 .. 25: 0'u32 else: uint32(r.data[i])
    crc = (crc shl 8) xor CrcTable[(crc shr 24) xor value]
  if crc != r.data.little32(p + 22):
    raise newException(OggError, "Invalid Ogg page checksum.")
  let serial = r.data.little32(p + 14)
  r.active = -1
  for i in 0 ..< r.count:
    if serial == r.streams[i].serial:
      r.active = i
  if (flags and 2) != 0:
    if r.body or r.active >= 0 or r.count == r.streams.len:
      raise newException(OggError, "Unsupported chained or duplicate stream.")
    r.active = r.count
    inc r.count
    r.streams[r.active].serial = serial
  else:
    r.body = true
  if r.active < 0:
    raise newException(OggError, "Unknown Ogg stream serial.")
  template stream: untyped = r.streams[r.active]
  if stream.eos or stream.sequence != r.data.little32(p + 18):
    raise newException(OggError, "Discontinuous Ogg page sequence.")
  if ((flags and 1) != 0) != (stream.partial.len > 0):
    raise newException(OggError, "Discontinuous Ogg packet.")
  inc stream.sequence
  stream.eos = (flags and 4) != 0
  if stream.eos and ((segments > 0 and ord(r.data[r.laceEnd - 1]) == 255) or
      (segments == 0 and stream.partial.len != 0)):
    raise newException(OggError, "Incomplete final Ogg packet.")
  r.granule = cast[int64](uint64(r.data.little32(p + 6)) or
    (uint64(r.data.little32(p + 10)) shl 32))
  true

proc nextPacket*(r: var PacketReader, packet: var Packet): bool
    {.raises: [OggError].} =
  ## Returns one complete packet in physical page order.
  while true:
    while r.lace == r.laceEnd:
      if not r.nextPage():
        return false
    let start = r.payload
    var complete = false
    while r.lace < r.laceEnd:
      let size = ord(r.data[r.lace])
      inc r.lace
      r.payload += size
      if size < 255:
        complete = true
        break
    template stream: untyped = r.streams[r.active]
    if start < r.payload:
      let offset = stream.partial.len
      stream.partial.setLen(offset + (r.payload - start))
      copyMem(addr stream.partial[offset], unsafeAddr r.data[start],
        r.payload - start)
    if complete:
      let last = r.lace - 1 == r.lastComplete
      packet = Packet(stream: r.active, number: stream.number,
        eos: last and stream.eos, granule: (if last: r.granule else: -1),
        data: move(stream.partial))
      inc stream.number
      return true
