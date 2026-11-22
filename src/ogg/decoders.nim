import common, packets, theora, vorbis
import profiles

type Decoder* = ref object
  reader: PacketReader
  audio: Vorbis
  video: Theora
  audioStream, videoStream: int
  error: string

proc close*(decoder: Decoder) {.raises: [].} =
  ## Releases compressed data and both codec states immediately.
  if decoder != nil:
    reset(decoder[])

proc validate(decoder: Decoder) {.raises: [OggError].} =
  ## Requires an open decoder.
  if decoder == nil or decoder.reader.data.len == 0:
    raise newException(OggError, "The Ogg decoder is closed.")

proc initialize(decoder: Decoder) {.raises: [OggError], measure.} =
  ## Identifies the logical streams and consumes their mandatory headers.
  decoder.audioStream = -1
  decoder.videoStream = -1
  var packet: Packet
  var ready = 0
  while decoder.reader.nextPacket(packet):
    if packet.number == 0:
      if packet.data.len < 7:
        raise newException(OggError, "Missing Ogg codec identification.")
      case packet.data[0..6]
      of "\x01vorbis":
        if decoder.audioStream >= 0:
          raise newException(OggError, "Duplicate Vorbis stream.")
        decoder.audioStream = packet.stream
      of "\x80theora":
        if decoder.videoStream >= 0:
          raise newException(OggError, "Duplicate Theora stream.")
        decoder.videoStream = packet.stream
      else:
        raise newException(OggError, "Unsupported Ogg codec.")
    if packet.stream == decoder.audioStream:
      decoder.audio.header(packet)
    else:
      decoder.video.header(packet)
    if packet.number == 2:
      inc ready
    if decoder.reader.body and ready == decoder.reader.count: return
  raise newException(OggError, "Missing Ogg codec headers.")

proc newOgg*(data: string): Decoder {.raises: [OggError].} =
  ## Retains compressed input for sequential decoding from the beginning.
  if data.len == 0:
    raise newException(OggError, "The Ogg input is empty.")
  result = Decoder(reader: PacketReader(data: data))
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
  decoder.audio.info

proc videoInfo*(decoder: Decoder): VideoInfo {.raises: [OggError].} =
  ## Returns video metadata, with zero dimensions when no video is present.
  decoder.validate()
  decoder.video.setup.info

proc hasAudio*(decoder: Decoder): bool {.raises: [OggError].} =
  ## Returns whether the input contains a Vorbis stream.
  decoder.audioInfo.channels > 0

proc hasVideo*(decoder: Decoder): bool {.raises: [OggError].} =
  ## Returns whether the input contains a Theora stream.
  decoder.videoInfo.width > 0

proc rewind*(decoder: Decoder) {.raises: [OggError].} =
  ## Reopens the retained compressed input and resets both streams to the start.
  decoder.validate()
  let data = move(decoder.reader.data)
  decoder.close()
  decoder.reader.data = data
  decoder.initialize()

proc readFrame*(decoder: Decoder, frame: var MediaFrame): bool
    {.raises: [OggError].} =
  ## Returns the next owned frame in container order, or false at clean EOF.
  decoder.validate()
  if decoder.error.len > 0:
    raise newException(OggError, decoder.error)
  try:
    var packet: Packet
    while decoder.reader.nextPacket(packet):
      if packet.stream == decoder.audioStream:
        let audio = decoder.audio.decode(packet)
        if audio.samples.len == 0: continue
        frame = MediaFrame(kind: Audio, audio: audio)
      else:
        frame = MediaFrame(kind: Video, video: decoder.video.decode(packet))
      return true
  except OggError as error:
    decoder.error = error.msg
    raise
