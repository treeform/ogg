import std/[os, unittest]
import ogg/[packets, vorbis, common, bindings]

proc compareAudio(path: string) =
  ## Compares packet-level timing, channel order, and PCM with libvorbis.
  let data = readFile(path)
  let oracle = referenceOpen(data[0].unsafeAddr, data.len.csize_t)
  defer: referenceClose(oracle)
  require referenceError(oracle) == nil
  var
    reader = PacketReader(data: data)
    packet: Packet
    audio: Vorbis
    stream = -1
    frame: ReferenceFrame
  while reader.nextPacket(packet):
    if packet.number == 0 and packet.data == "": continue
    if packet.number == 0 and packet.data[0] == '\x01': stream = packet.stream
    if packet.stream != stream: continue
    if packet.number < 3:
      audio.header(packet)
    else:
      let decoded = audio.decode(packet)
      if decoded.samples.len == 0: continue
      while true:
        require referenceRead(oracle, addr frame) == 1
        if frame.kind == 1: break
      require frame.samples.int * decoded.channels == decoded.samples.len
      check frame.time == decoded.time
      var peak = 0.0
      for i, sample in decoded.samples:
        peak = max(peak, abs(float64(sample - frame.pcm[i mod decoded.channels][i div decoded.channels])))
      check peak < 0.00001
  while referenceRead(oracle, addr frame) == 1:
    check frame.kind != 1

suite "Native Vorbis packets":
  for name in ["mono.ogg", "stereo.ogg", "silence.ogg", "continued.ogg", "mixed.ogv"]:
    test name:
      compareAudio(currentSourcePath().parentDir / "data" / name)

