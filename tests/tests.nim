import
  std/[json, math, os, unittest],
  ogg

const
  DataPath = currentSourcePath().parentDir / "data"
  Manifest = staticRead("data/manifest.json")

proc readFloat(data: string, index: int): float32 =
  ## Reads an independent little-endian PCM sample without alignment assumptions.
  var bits: uint32
  for i in 0 ..< 4:
    bits = bits or (uint32(uint8(data[index * 4 + i])) shl (i * 8))
  return cast[float32](bits)

proc pageSize(data: string, offset: int): int =
  ## Returns the size of a complete fixture page from its lacing table.
  let segments = int(uint8(data[offset + 26]))
  result = 27 + segments
  for i in 0 ..< segments:
    result += int(uint8(data[offset + 27 + i]))

proc checksum(data: var string, offset: int) =
  ## Recomputes a page CRC so structural mutations reach the demuxer.
  for i in 22 .. 25:
    data[offset + i] = '\0'
  var crc: uint32
  for i in offset ..< offset + data.pageSize(offset):
    crc = crc xor (uint32(uint8(data[i])) shl 24)
    for bit in 0 ..< 8:
      if (crc and 0x80000000'u32) != 0:
        crc = (crc shl 1) xor 0x04c11db7'u32
      else:
        crc = crc shl 1
  for i in 0 ..< 4:
    data[offset + 22 + i] = char((crc shr (i * 8)) and 255)

proc consume(data: string) =
  ## Decodes through EOF so late errors cannot be mistaken for success.
  let decoder = newOgg(data)
  defer: decoder.close()
  var frame: MediaFrame
  while decoder.readFrame(frame):
    discard

proc `==`(a, b: MediaFrame): bool =
  ## Compares only the active branch of two owned media frames.
  if a.kind != b.kind:
    return false
  case a.kind
  of Audio:
    return a.audio == b.audio
  of Video:
    return a.video == b.video

proc verifyCorpus(item: JsonNode) =
  ## Compares every decoded sample and visible plane against independent output.
  let decoder = openOgg(DataPath / item["file"].getStr)
  defer: decoder.close()
  let
    audio = decoder.audioInfo
    video = decoder.videoInfo
    audioReference =
      if item.hasKey("audio_reference"):
        readFile(DataPath / item["audio_reference"].getStr)
      else:
        ""
    videoReference =
      if item.hasKey("video_reference"):
        readFile(DataPath / item["video_reference"].getStr)
      else:
        ""
  check decoder.hasAudio == item.hasKey("channels")
  check decoder.hasVideo == item.hasKey("width")
  if decoder.hasAudio:
    check audio.channels == item["channels"].getInt
    check audio.sampleRate == item["rate"].getInt
  if decoder.hasVideo:
    check video.width == item["width"].getInt
    check video.height == item["height"].getInt
    check video.frameRate == 12
    check video.fpsNumerator == 12
    check video.fpsDenominator == 1
  var
    frame: MediaFrame
    samples, frames, pixels: int
    audioDifference, audioMaximum: float64
    videoDifference, videoMaximum: int
    energy: array[8, float64]
  while decoder.readFrame(frame):
    case frame.kind
    of Audio:
      let decoded = frame.audio
      check decoded.channels == audio.channels
      check decoded.sampleRate == audio.sampleRate
      check decoded.samples.len > 0
      check decoded.samples.len mod audio.channels == 0
      check abs(decoded.time - float64(samples div audio.channels) /
        float64(audio.sampleRate)) < 1e-9
      require (samples + decoded.samples.len) * 4 <= audioReference.len
      for i, sample in decoded.samples:
        let difference = abs(float64(sample - readFloat(audioReference, samples + i)))
        check classify(sample) notin {fcNan, fcInf, fcNegInf}
        audioDifference += difference * difference
        audioMaximum = max(audioMaximum, difference)
        energy[i mod audio.channels] += float64(sample) * float64(sample)
      samples += decoded.samples.len
    of Video:
      let decoded = frame.video
      check decoded.info == video
      check abs(decoded.time - float64(frames) / video.frameRate) < 1e-9
      for plane in 0 ..< 3:
        let
          shiftX = int(plane != 0 and video.pixelFormat != Yuv444)
          shiftY = int(plane != 0 and video.pixelFormat == Yuv420)
          width = (video.width + shiftX) shr shiftX
          height = (video.height + shiftY) shr shiftY
          offsetX = video.offsetX shr shiftX
          offsetY = video.offsetY shr shiftY
          actual = decoded.planes[plane]
        check actual.data.len == actual.width * actual.height
        check actual.width >= width + offsetX
        check actual.height >= height + offsetY
        require pixels + width * height <= videoReference.len
        for y in 0 ..< height:
          for x in 0 ..< width:
            let
              value = actual.data[(y + offsetY) * actual.width + x + offsetX]
              expected = uint8(videoReference[pixels])
              difference = abs(int(value) - int(expected))
            videoDifference += difference
            videoMaximum = max(videoMaximum, difference)
            inc pixels
      let rgba = decoded.rgba
      check rgba.len == video.width * video.height * 4
      for i in countup(3, rgba.high, 4):
        check rgba[i] == 255
      inc frames
  check not decoder.readFrame(frame)
  check samples * 4 == audioReference.len
  check pixels == videoReference.len
  if samples > 0:
    check samples div audio.channels == item["samples"].getInt
    check sqrt(audioDifference / float64(samples)) < 0.000001
    check audioMaximum < 0.00001
    if item["name"].getStr == "silence":
      check energy[0] == 0
    else:
      check energy[0] > 1
    if audio.channels == 2:
      check energy[0] / energy[1] > 3.5
      check energy[0] / energy[1] < 4.5
  if frames > 0:
    check frames == item["frames"].getInt
    # Independent integer IDCT implementations can differ by one rounding unit.
    check videoMaximum <= 2
    check float64(videoDifference) / float64(pixels) < 0.1

suite "Reference corpus":
  for item in parseJson(Manifest)["cases"]:
    test item["name"].getStr:
      verifyCorpus(item)

suite "Ownership and lifecycle":
  test "compressed input and output survive caller mutation and decoder close":
    var data = readFile(DataPath / "mixed.ogv")
    let decoder = newOgg(data)
    data[0] = 'X'
    data.setLen(0)
    var first, next: MediaFrame
    require decoder.readFrame(first)
    let saved = $first
    while decoder.readFrame(next):
      discard
    check $first == saved
    decoder.close()
    decoder.close()
    check $first == saved
    expect OggError:
      discard decoder.readFrame(next)

  test "rewind resets both streams and EOF leaves the last frame unchanged":
    let decoder = openOgg(DataPath / "mixed.ogv")
    defer: decoder.close()
    var first, frame: MediaFrame
    require decoder.readFrame(first)
    while decoder.readFrame(frame):
      discard
    let last = frame
    check not decoder.readFrame(frame)
    check frame == last
    decoder.rewind()
    require decoder.readFrame(frame)
    check frame == first

  test "Unicode paths and missing files use Nim IO and OggError":
    let path = getTempDir() / ("ogg-映画-" & $getCurrentProcessId() & ".ogg")
    copyFile(DataPath / "mono.ogg", path)
    defer: removeFile(path)
    let decoder = openOgg(path)
    decoder.close()
    for path in ["", "bad\0path", DataPath / "missing.ogg"]:
      expect OggError:
        discard openOgg(path)
    var missing: Decoder
    missing.close()
    expect OggError:
      discard missing.audioInfo

  test "float samples convert to clipped signed PCM":
    let frame = AudioFrame(samples: @[-2.0'f, -1, 0, 0.5, 1, 2])
    check frame.pcm16 == @[-32767'i16, -32767, 0, 16384, 32767, 32767]

suite "Malformed and unsupported inputs":
  test "empty, foreign, incomplete, and corrupt input fails explicitly":
    for data in ["", "not an Ogg file", "OggS\0"]:
      expect OggError:
        consume(data)
    let valid = readFile(DataPath / "mixed.ogv")
    for length in [1, 26, 80, valid.len div 2, valid.len - 1]:
      expect OggError:
        consume(valid[0 ..< length])
    var corrupt = valid
    corrupt[corrupt.high] = char(uint8(corrupt[^1]) xor 1)
    expect OggError:
      consume(corrupt)
    expect OggError:
      consume(valid & "junk")

  test "valid CRC does not hide missing EOS, missing pages, or unsupported codecs":
    let valid = readFile(DataPath / "stereo.ogg")
    var
      offset = 0
      last = 0
    while offset < valid.len:
      last = offset
      offset += valid.pageSize(offset)
    var data = valid
    data[last + 5] = char(uint8(data[last + 5]) and 0xfb)
    data.checksum(last)
    expect OggError:
      consume(data)
    data = valid
    data[last + 18] = char(uint8(data[last + 18]) + 1)
    data.checksum(last)
    expect OggError:
      consume(data)
    data = valid
    let header = 27 + int(uint8(data[26]))
    data[header + 1] = 'X'
    data.checksum(0)
    expect OggError:
      consume(data)

  test "chained logical streams report unsupported instead of silently stopping":
    let data = readFile(DataPath / "mono.ogg")
    expect OggError:
      consume(data & data)

  test "a decoder keeps its first error until rewound or closed":
    var data = readFile(DataPath / "stereo.ogg")
    data.setLen(data.len - 1)
    let decoder = newOgg(data)
    defer: decoder.close()
    var frame: MediaFrame
    expect OggError:
      while decoder.readFrame(frame):
        discard
    expect OggError:
      discard decoder.readFrame(frame)

import test_packets
import test_vorbis
