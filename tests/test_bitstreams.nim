import std/unittest
import ogg/bitstreams

suite "Codec bit fields":
  test "wide and trailing reads agree with individual bits at every alignment":
    let bytes = "\xf0\x21\xaf\x76\xe2\x94\x13\x80"
    for msb in [false, true]:
      for start in 0 ..< bytes.len * 8:
        for width in 0 .. 32:
          var r = BitReader(data: bytes, pos: start div 8, msb: msb)
          discard r.readUnsigned(start mod 8)
          if width > bytes.len * 8 - start:
            expect EndOfPacket: discard r.readUnsigned(width)
          else:
            var expected: uint32
            for i in 0 ..< width:
              let p = start + i
              let bit = if msb: 7 - p mod 8 else: p mod 8
              let shift = if msb: width - 1 - i else: i
              expected = expected or (((uint32(bytes[p div 8]) shr bit) and 1) shl shift)
            check r.readUnsigned(width) == expected
            if start + width < bytes.len * 8:
              let p = start + width
              let bit = if msb: 7 - p mod 8 else: p mod 8
              check r.readBit(msb) == ((ord(bytes[p div 8]) shr bit) and 1)
