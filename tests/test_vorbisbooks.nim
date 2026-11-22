import std/unittest
import ogg/[bitstreams, common, vorbisbooks]

proc readLengths(lengths: openArray[int]): Book =
  ## Packs a dense, unordered scalar book into a Vorbis setup bitstream.
  var data = ""
  var pos = 0
  proc put(value, width: int) =
    for i in 0 ..< width:
      if pos mod 8 == 0: data.add('\0')
      data[^1] = char(ord(data[^1]) or (((value shr i) and 1) shl (pos mod 8)))
      inc pos
  put(0x564342, 24)
  put(1, 16)
  put(lengths.len, 24)
  put(0, 2)
  for length in lengths: put(length - 1, 5)
  put(0, 4)
  var reader = BitReader(data: data)
  var budget = 100
  reader.readBook(budget)

suite "Vorbis prefix allocation":
  test "out-of-order lengths through 32 bits retain their entry numbers":
    var lengths = @[32]
    for depth in 1 .. 32: lengths.add(depth)
    let book = readLengths(lengths)
    for entry in 0 .. 32:
      var bits = newString(4)
      if entry > 0:
        bits[(entry - 1) div 8] = char(1 shl ((entry - 1) mod 8))
      var r = BitReader(data: bits)
      check r.scalar(book) == entry

  test "incomplete and oversubscribed books are rejected":
    expect OggError: discard readLengths([2, 2])
    expect OggError: discard readLengths([1, 1, 1])
    discard readLengths([1])
