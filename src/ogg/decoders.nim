import
  bindings, common

type
  DecoderObj = object
    handle: ptr Reference
    data: string
    audio: AudioInfo
    video: VideoInfo

  Decoder* = ref DecoderObj

proc release(decoder: var DecoderObj) {.raises: [].} =
  ## Releases native state before the compressed input it borrows.
  if decoder.handle != nil:
    referenceClose(decoder.handle)
    decoder.handle = nil
  decoder.data = ""

proc `=destroy`(decoder: var DecoderObj) {.raises: [].} =
  ## Releases the native decoder when its last Nim reference is dropped.
  decoder.release()

proc close*(decoder: Decoder) {.raises: [].} =
  ## Releases a decoder immediately; closing nil or closed decoders is harmless.
  if decoder != nil:
    decoder[].release()

proc validate(decoder: Decoder) {.raises: [OggError].} =
  ## Rejects a closed decoder before passing its handle to C.
  if decoder == nil or decoder.handle == nil:
    raise newException(OggError, "The Ogg decoder is closed.")

proc initialize(decoder: Decoder) {.raises: [OggError].} =
  ## Opens the pinned reference decoder and records both streams' metadata.
  decoder.handle = referenceOpen(
    unsafeAddr decoder.data[0], csize_t(decoder.data.len)
  )
  let error = referenceError(decoder.handle)
  if error != nil:
    let message = $error
    decoder.close()
    raise newException(OggError, message)
  let info = referenceInfo(decoder.handle)
  var format: PixelFormat
  case info.pixelFormat
  of 0: format = Yuv420
  of 2: format = Yuv422
  of 3: format = Yuv444
  else:
    decoder.close()
    raise newException(OggError, "Unsupported Theora pixel format.")
  decoder.audio = AudioInfo(
    channels: int(info.channels), sampleRate: int(info.sampleRate)
  )
  decoder.video = VideoInfo(
    width: int(info.width), height: int(info.height),
    offsetX: int(info.offsetX), offsetY: int(info.offsetY),
    pixelFormat: format,
    fpsNumerator: uint32(info.fpsNumerator),
    fpsDenominator: uint32(info.fpsDenominator)
  )

proc newOgg*(data: string): Decoder {.raises: [OggError].} =
  ## Retains compressed input for sequential decoding from the beginning.
  if data.len == 0:
    raise newException(OggError, "The Ogg input is empty.")
  result = Decoder(data: data)
  result.initialize()

proc openOgg*(path: string): Decoder {.raises: [OggError].} =
  ## Reads a file into memory and opens it, including Unicode file paths.
  if path.len == 0 or '\0' in path:
    raise newException(OggError, "The Ogg file path is empty or invalid.")
  try:
    return newOgg(readFile(path))
  except IOError as error:
    raise newException(OggError, "Cannot read Ogg file: " & error.msg)

proc audioInfo*(decoder: Decoder): AudioInfo {.raises: [OggError].} =
  ## Returns audio metadata, with zero channels when no audio is present.
  decoder.validate()
  return decoder.audio

proc videoInfo*(decoder: Decoder): VideoInfo {.raises: [OggError].} =
  ## Returns video metadata, with zero dimensions when no video is present.
  decoder.validate()
  return decoder.video

proc hasAudio*(decoder: Decoder): bool {.raises: [OggError].} =
  ## Returns whether the input contains a Vorbis stream.
  decoder.audioInfo.channels > 0

proc hasVideo*(decoder: Decoder): bool {.raises: [OggError].} =
  ## Returns whether the input contains a Theora stream.
  decoder.videoInfo.width > 0

proc rewind*(decoder: Decoder) {.raises: [OggError].} =
  ## Reopens the retained compressed input and resets both streams to the start.
  decoder.validate()
  referenceClose(decoder.handle)
  decoder.handle = nil
  decoder.initialize()

proc readFrame*(decoder: Decoder, frame: var MediaFrame): bool
    {.raises: [OggError].} =
  ## Copies the next audio or video packet's output in container order.
  ## Returns false only at clean EOF and leaves frame unchanged on EOF or error.
  decoder.validate()
  var native: ReferenceFrame
  let status = referenceRead(decoder.handle, addr native)
  if status < 0:
    raise newException(OggError, $referenceError(decoder.handle))
  if status == 0:
    return false
  if native.kind == 1:
    let info = decoder.audio
    var audio = AudioFrame(
      time: native.time, channels: info.channels, sampleRate: info.sampleRate,
      samples: newSeq[float32](int(native.samples) * info.channels)
    )
    for i in 0 ..< int(native.samples):
      for channel in 0 ..< info.channels:
        audio.samples[i * info.channels + channel] = native.pcm[channel][i]
    frame = MediaFrame(kind: Audio, audio: audio)
  else:
    var video = VideoFrame(time: native.time, info: decoder.video)
    for i in 0 ..< 3:
      let
        width = int(native.widths[i])
        height = int(native.heights[i])
      video.planes[i] = Plane(
        width: width, height: height, data: newSeq[uint8](width * height)
      )
      for y in 0 ..< height:
        copyMem(
          addr video.planes[i].data[y * width],
          addr native.planes[i][y * int(native.strides[i])],
          width
        )
    frame = MediaFrame(kind: Video, video: video)
  return true
