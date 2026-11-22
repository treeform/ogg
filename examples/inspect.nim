import
  std/os,
  ogg

proc main() =
  ## Prints stream metadata and counts all decoded frames without playback.
  if paramCount() != 1:
    quit("Usage: inspect <file.ogg|file.ogv>")
  let decoder = openOgg(paramStr(1))
  defer: decoder.close()
  echo "Audio: ", decoder.audioInfo
  echo "Video: ", decoder.videoInfo
  var
    frame: MediaFrame
    samples, frames: int
  while decoder.readFrame(frame):
    case frame.kind
    of Audio:
      samples += frame.audio.samples.len div frame.audio.channels
    of Video:
      inc frames
  echo "Decoded ", samples, " sample frames and ", frames, " video frames."

main()
