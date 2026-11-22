import std/[os, unittest]
import reference/bindings
import ogg/[common, packets, theoradct, theorasetup]

proc referenceDct(output, input: var DctBlock, last: cint)
    {.importc: "oc_idct8x8_c".}

suite "Native Theora transforms and headers":
  test "fixed-point inverse DCT agrees with libtheora":
    var state = 1'u32
    for i in 0 .. 255:
      var input, expected: DctBlock
      for value in input.mitems:
        state = state * 1664525'u32 + 1013904223'u32
        value = cast[int16](uint16(state shr 16))
      var actual = input
      referenceDct(expected, input, 64)
      actual.inverseDct()
      check actual == expected

  test "sparse transforms agree with libtheora at both cutoffs":
    const zigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24]
    var state = 19'u32
    for count in 2 .. 10:
      for trial in 0 ..< 32:
        var input, expected: DctBlock
        for i in 0 ..< count:
          state = state * 1664525'u32 + 1013904223'u32
          input[zigzag[i]] = cast[int16](uint16(state shr 16))
        var actual = input
        referenceDct(expected, input, cint(count))
        actual.inverseDct(count)
        check actual == expected

  for name in ["video420", "video422", "video444"]:
    test name & " headers":
      let data = readFile(currentSourcePath().parentDir / "data" / (name & ".ogv"))
      var reader = PacketReader(data: data)
      var packet: Packet
      var setup: TheoraSetup
      for i in 0 .. 2:
        require reader.nextPacket(packet)
        setup.header(packet)
        var truncated = packet
        truncated.data.setLen(7)
        expect OggError:
          setup.header(truncated)
      let oracle = referenceOpen(data[0].unsafeAddr, csize_t(data.len))
      defer: referenceClose(oracle)
      require referenceError(oracle) == nil
      let info = referenceInfo(oracle)
      check setup.info.width == info.width
      check setup.info.height == info.height
      check ord(setup.info.pixelFormat) == info.pixelFormat

