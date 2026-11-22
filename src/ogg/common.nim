import std/math

type
  OggError* = object of CatchableError

  FrameKind* = enum
    Audio, Video

  PixelFormat* = enum
    Yuv420 = 0, Yuv422 = 2, Yuv444 = 3

  AudioInfo* = object
    channels*, sampleRate*: int

  VideoInfo* = object
    width*, height*: int
    offsetX*, offsetY*: int
    pixelFormat*: PixelFormat
    fpsNumerator*, fpsDenominator*: uint32

  Plane* = object
    width*, height*: int
    data*: seq[uint8]
      ## Tightly packed rows including the codec's padded picture borders.

  AudioFrame* = object
    time*: float64
    channels*, sampleRate*: int
    samples*: seq[float32]
      ## Interleaved PCM in Vorbis channel order, without remixing or clipping.

  VideoFrame* = object
    time*: float64
    info*: VideoInfo
    planes*: array[3, Plane]
      ## Owned full Y, Cb, and Cr planes; info describes the visible rectangle.

  MediaFrame* = object
    case kind*: FrameKind
    of Audio:
      audio*: AudioFrame
    of Video:
      video*: VideoFrame

proc frameRate*(info: VideoInfo): float64 {.raises: [].} =
  ## Returns frames per second, or zero when no video is present.
  if info.fpsDenominator == 0:
    return 0
  return float64(info.fpsNumerator) / float64(info.fpsDenominator)

proc pcm16*(frame: AudioFrame): seq[int16] {.raises: [].} =
  ## Converts float samples to signed PCM, clipping at full scale.
  result.setLen(frame.samples.len)
  for i, sample in frame.samples:
    result[i] = int16(round(clamp(sample, -1.0'f, 1.0'f) * 32767.0'f))

proc rgba*(frame: VideoFrame): seq[uint8] {.raises: [].} =
  ## Converts the visible rectangle using limited-range BT.601 and nearest chroma.
  let
    info = frame.info
    shiftX = int(info.pixelFormat != Yuv444)
    shiftY = int(info.pixelFormat == Yuv420)
  result.setLen(info.width * info.height * 4)
  for y in 0 ..< info.height:
    for x in 0 ..< info.width:
      let
        px = x + info.offsetX
        py = y + info.offsetY
        luma = int(frame.planes[0].data[py * frame.planes[0].width + px]) - 16
        chroma = (py shr shiftY) * frame.planes[1].width + (px shr shiftX)
        cb = int(frame.planes[1].data[chroma]) - 128
        cr = int(frame.planes[2].data[chroma]) - 128
        i = (y * info.width + x) * 4
      result[i] = uint8(clamp((298 * luma + 409 * cr + 128) shr 8, 0, 255))
      result[i + 1] = uint8(clamp(
        (298 * luma - 100 * cb - 208 * cr + 128) shr 8, 0, 255
      ))
      result[i + 2] = uint8(clamp((298 * luma + 516 * cb + 128) shr 8, 0, 255))
      result[i + 3] = 255
