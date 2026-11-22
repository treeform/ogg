## Compares the public Nim decoder to the pinned C reference packet by packet.
import std/[os, unittest]
import ogg, ogg/bindings

proc compareReference*(path: string) =
  ## Compares every frame, including padded video planes and exact EOF.
  let data = readFile(path)
  let decoder = newOgg(data)
  let oracle = referenceOpen(data[0].unsafeAddr, csize_t(data.len))
  defer:
    referenceClose(oracle)
    decoder.close()
  require referenceError(oracle) == nil
  var actual: MediaFrame
  var expected: ReferenceFrame
  while decoder.readFrame(actual):
    require referenceRead(oracle, addr expected) == 1
    case actual.kind
    of Audio:
      require expected.kind == 1
      let channels = actual.audio.channels
      require actual.audio.samples.len == int(expected.samples) * channels
      check actual.audio.time == expected.time
      var peak = 0.0
      for i, sample in actual.audio.samples:
        let diff = abs(float64(sample - expected.pcm[i mod channels][i div channels]))
        require diff == diff
        peak = max(peak, diff)
      check peak < 0.00001
    of Video:
      require expected.kind == 2
      check actual.video.time == expected.time
      for p, plane in actual.video.planes:
        require plane.width == expected.widths[p]
        require plane.height == expected.heights[p]
        for y in 0 ..< plane.height:
          require equalMem(plane.data[y * plane.width].unsafeAddr,
            expected.planes[p][y * expected.strides[p]].unsafeAddr, plane.width)
  check referenceRead(oracle, addr expected) == 0

when isMainModule:
  for path in commandLineParams(): compareReference(path)
else:
  suite "Public decoder against Xiph reference":
    for path in walkFiles(currentSourcePath().parentDir / "data" / "*.og?"):
      test path.extractFilename:
        compareReference(path)
