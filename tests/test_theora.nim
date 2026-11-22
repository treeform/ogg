import std/[os, unittest]
import reference/bindings
import ogg/[common, packets, simd, theoradct, theorasetup]
when useX86Simd: import ogg/kernelsavx2
when useNeon: import ogg/kernelsneon

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

  when useX86Simd:
    test "AVX2 reconstruction preserves row padding and clips signed residuals":
      if hasAvx2:
        const
          stride = 11
          offset = 7*stride + 2
          first = 7*stride + 1
          second = 8*stride + 3
          levels = [low(int16), -256, -128, -1, 0, 1, 127, high(int16)]
        var reference: array[9*stride, uint8]
        var residual: DctBlock
        for i in 0 ..< reference.len: reference[i] = uint8((i*31) mod 256)
        for i in 0 ..< 64: residual[i] = levels[(i + i div 8) mod 8]
        for mode in 0 .. 2:
          var expected: array[8*stride, uint8]
          for value in expected.mitems: value = 91
          var actual = expected
          for row in 0 ..< 8:
            for x in 0 ..< 8:
              let at = x - row*stride
              let a = int(reference[first + at])
              let prediction = case mode
                of 0: 128
                of 1: a
                else: (a + int(reference[second + at])) div 2
              expected[offset + at] = uint8(clamp(prediction + int(residual[8*row+x]), 0, 255))
          if mode == 0:
            writeBlockAvx2(actual, offset, stride, residual, [], 0, 0)
          else:
            let b = if mode == 1: first else: second
            writeBlockAvx2(actual, offset, stride, residual, reference, first, b)
          check actual == expected
      else:
        skip()

  when useNeon:
    test "NEON reconstruction preserves row padding and clips signed residuals":
      const
        stride = 11
        offset = 7*stride + 2
        first = 7*stride + 1
        second = 8*stride + 3
        levels = [low(int16), -256, -128, -1, 0, 1, 127, high(int16)]
      var reference: array[9*stride, uint8]
      var residual: DctBlock
      for i in 0 ..< reference.len: reference[i] = uint8((i*31) mod 256)
      for i in 0 ..< 64: residual[i] = levels[(i + i div 8) mod 8]
      for mode in 0 .. 2:
        var expected: array[8*stride, uint8]
        for value in expected.mitems: value = 91
        var actual = expected
        for row in 0 ..< 8:
          for x in 0 ..< 8:
            let at = x - row*stride
            let a = int(reference[first + at])
            let prediction = case mode
              of 0: 128
              of 1: a
              else: (a + int(reference[second + at])) div 2
            expected[offset + at] = uint8(clamp(prediction + int(residual[8*row+x]), 0, 255))
        if mode == 0:
          writeBlockNeon(actual, offset, stride, residual, [], 0, 0)
        else:
          let b = if mode == 1: first else: second
          writeBlockNeon(actual, offset, stride, residual, reference, first, b)
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

