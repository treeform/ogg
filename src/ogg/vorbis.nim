## Derived from libvorbis, copyright (c) 2002-2020 Xiph.org Foundation.
## Redistribution terms are in licenses/vorbis.txt.
## Native Vorbis I packet synthesis.
import std/complex
import profiles
import bitstreams, common, packets, vorbisbooks, vorbisfloors, vorbistransforms

type
  Residue = object
    kind, first, limit, grouping, phrase, passes: int
    stages: seq[array[8, int]]

  Mapping = object
    mux: seq[int]
    coupling: seq[tuple[mag, angle: int]]
    floors, residues: seq[int]

  Mode = object
    long: bool
    mapping: int

  Vorbis* = object
    info*: AudioInfo
    sizes: array[2, int]
    books: seq[Book]
    floors: seq[Floor]
    residues: seq[Residue]
    mappings: seq[Mapping]
    modes: seq[Mode]
    plans: array[2, MdctPlan]
    windows: array[2, seq[float64]]
    fftWork: seq[Complex64]
    current, previous: seq[seq[float64]]
    samples, nominal, granule: int64

proc readResidue(r: var BitReader, books: seq[Book]): Residue =
  ## Reads the partition sizes and eight vector-quantization passes.
  result.kind = r.read(16)
  if result.kind > 2: invalid("Unsupported Vorbis residue type.")
  result.first = r.read(24)
  result.limit = r.read(24)
  result.grouping = r.read(24) + 1
  let count = r.read(6) + 1
  result.phrase = r.bookIndex(books)
  var classifications = 1
  let phrase = addr books[result.phrase]
  for i in 0 ..< phrase.dimension:
    if classifications > phrase.entries div count:
      invalid("Vorbis residue classifications exceed the phrasebook.")
    classifications *= count
  var masks = newSeq[int](count)
  for mask in masks.mitems:
    mask = r.read(3)
    if r.flag(): mask = mask or (r.read(5) shl 3)
  for mask in masks:
    result.passes = max(result.passes, ilog(mask))
    var stages: array[8, int]
    for i in 0 ..< 8:
      stages[i] = -1
      if (mask and (1 shl i)) != 0:
        stages[i] = r.bookIndex(books)
        if books[stages[i]].lookup == 0: invalid("Missing Vorbis residue vectors.")
    result.stages.add(stages)

proc readMapping(r: var BitReader, v: Vorbis): Mapping =
  ## Reads channel coupling and the per-channel floor and residue routing.
  if r.read(16) != 0: invalid("Unsupported Vorbis mapping type.")
  let count = if r.flag(): r.read(4) + 1 else: 1
  if r.flag():
    for i in 0 .. r.read(8):
      let bits = ilog(v.info.channels - 1)
      let m = r.read(bits)
      let a = r.read(bits)
      if m == a or max(a, m) >= v.info.channels: invalid("Invalid channel coupling.")
      result.coupling.add((m, a))
  if r.read(2) != 0: invalid("Invalid Vorbis mapping flags.")
  for i in 0 ..< v.info.channels:
    let mux = if count == 1: 0 else: r.read(4)
    if mux >= count: invalid("Invalid Vorbis submap.")
    result.mux.add(mux)
  for i in 0 ..< count:
    discard r.read(8)
    let f = r.read(8)
    let s = r.read(8)
    if f >= v.floors.len or s >= v.residues.len: invalid("Invalid Vorbis mapping.")
    result.floors.add(f)
    result.residues.add(s)

proc header*(v: var Vorbis, packet: Packet) =
  ## Consumes one of the three mandatory headers in stream order.
  if packet.number notin 0'i64 .. 2 or packet.data.len < 7 or
      ord(packet.data[0]) != 1 + 2 * packet.number or packet.data[1..6] != "vorbis":
    invalid("Invalid Vorbis header.")
  var r = BitReader(data: packet.data, pos: 7)
  case packet.number
  of 0:
    if r.readUnsigned(32) != 0: invalid("Unsupported Vorbis version.")
    v.info.channels = r.read(8)
    v.info.sampleRate = r.read(32)
    if v.info.channels notin 1 .. 8 or v.info.sampleRate notin 1 .. 384000:
      invalid("Unsupported Vorbis channel count or sample rate.")
    for i in 0 ..< 3: discard r.readUnsigned(32)
    let small = r.read(4)
    let large = r.read(4)
    if small < 6 or large < small or large > 13 or not r.flag():
      invalid("Invalid Vorbis block sizes or framing bit.")
    v.sizes = [1 shl small, 1 shl large]
    v.granule = -1
  of 1: comments(packet.data, true)
  else:
    # Combined limit for codebook entries and packed lookup values.
    var budget = 8 * 1024 * 1024
    for i in 0 .. r.read(8): v.books.add(r.readBook(budget))
    for i in 0 .. r.read(6):
      if r.read(16) != 0: invalid("Unsupported Vorbis time transform.")
    for i in 0 .. r.read(6): v.floors.add(r.readFloor(v.books))
    for i in 0 .. r.read(6): v.residues.add(r.readResidue(v.books))
    for i in 0 .. r.read(6): v.mappings.add(r.readMapping(v))
    for i in 0 .. r.read(6):
      var mode = Mode(long: r.flag())
      if r.read(16) != 0 or r.read(16) != 0: invalid("Unsupported Vorbis transform.")
      mode.mapping = r.read(8)
      if mode.mapping >= v.mappings.len: invalid("Invalid Vorbis mode mapping.")
      v.modes.add(mode)
    if not r.flag(): invalid("Missing Vorbis setup framing bit.")

proc residue(r: var BitReader, s: Residue, books: seq[Book], channels: seq[int],
    spectrum: var seq[seq[float64]]) {.measure.} =
  ## Decodes the residue passes into planar or channel-interleaved bins.
  if channels.len == 0: return
  let
    coupled = s.kind == 2
    lanes = if coupled: 1 else: channels.len
    bins = spectrum[0].len * (if coupled: channels.len else: 1)
    parts = (min(s.limit, bins) - s.first) div s.grouping
    dim = books[s.phrase].dimension
  if parts <= 0: return
  var classes = newSeq[int](lanes * parts)
  for stage in 0 ..< s.passes:
    var part = 0
    while part < parts:
      if stage == 0:
        for lane in 0 ..< lanes:
          var word = r.scalar(books[s.phrase])
          for j in countdown(dim - 1, 0):
            if j < parts - part:
              classes[lane * parts + part + j] = word mod s.stages.len
            word = word div s.stages.len
          if word != 0: invalid("Invalid Vorbis residue classword.")
      for j in 0 ..< min(dim, parts - part):
        for lane in 0 ..< lanes:
          let index = s.stages[classes[lane * parts + part]][stage]
          if index < 0: continue
          template book: untyped = books[index]
          let start = s.first + part * s.grouping
          if s.kind == 0:
            let step = s.grouping div book.dimension
            var entries = newSeq[int](step)
            for entry in entries.mitems: entry = r.scalar(book)
            for i, entry in entries:
              var dest = start + i
              for value in book.vector(entry):
                spectrum[channels[lane]][dest] += value
                dest += step
          else:
            var dest = start
            while dest < start + s.grouping:
              let entry = r.scalar(book)
              for value in book.vector(entry):
                if coupled:
                  spectrum[channels[dest mod channels.len]][dest div channels.len] += value
                else:
                  spectrum[channels[lane]][dest] += value
                inc dest
                if dest == start + s.grouping: break
        inc part

proc uncouple(mag, angle: var openArray[float64]) =
  ## Reverses channel coupling in place on two equally sized planes.
  for i in 0 ..< mag.len:
    let m = mag[i]
    let a = angle[i]
    if a > 0:
      angle[i] = if m > 0: m - a else: m + a
    else:
      angle[i] = m
      mag[i] = if m > 0: m + a else: m - a

proc overlapChannel(previous, current, window: openArray[float64],
    first, limit, ch, channels: int, output: var openArray[float32]) =
  ## Writes the leading, overlapping and trailing parts of one channel.
  let prev = previous.len
  let offset = (current.len - prev) div 4
  let start = max(0, -offset)
  let mid = clamp(start, first, limit)
  let tail = clamp(start + window.len, first, limit)
  var dest = ch
  for i in first ..< mid:
    output[dest] = float32(previous[prev div 2 + i])
    dest += channels
  for i in mid ..< tail:
    let t = i - start
    output[dest] = float32(previous[prev div 2 + i] * window[window.high - t] +
      current[i + offset] * window[t])
    dest += channels
  for i in tail ..< limit:
    output[dest] = float32(current[i + offset])
    dest += channels

proc decode*(v: var Vorbis, packet: Packet): AudioFrame {.measure.} =
  ## Synthesizes and trims a packet, retaining its right half for overlap.
  var r = BitReader(data: packet.data)
  if r.flag(): invalid("Expected Vorbis audio packet.")
  let modeIndex = r.read(ilog(v.modes.len - 1))
  if modeIndex >= v.modes.len: invalid("Invalid Vorbis audio mode.")
  let mode = v.modes[modeIndex]
  let n = v.sizes[int(mode.long)]
  if mode.long: discard r.read(2)
  template mapping: untyped = v.mappings[mode.mapping]
  let channels = v.info.channels
  var
    gains: seq[seq[float64]]
    used: seq[bool]
  template pcm: untyped = v.current
  pcm.setLen(channels)
  for channel in 0 ..< channels:
    let f = mapping.floors[mapping.mux[channel]]
    try:
      gains.add(r.decodeFloor(v.floors[f], v.books, n div 2))
    except EndOfPacket:
      # Vorbis I permits audio packets to end during floor decoding.
      gains.add(newSeq[float64]())
    used.add(gains[^1].len != 0)
    pcm[channel].setLen(n div 2)
    zeroMem(addr pcm[channel][0], (n div 2) * sizeof(float64))
  for pair in mapping.coupling:
    if used[pair.mag] or used[pair.angle]:
      used[pair.mag] = true
      used[pair.angle] = true
  for submap, index in mapping.residues:
    var bundle: seq[int]
    var active = false
    for ch, mux in mapping.mux:
      if mux == submap:
        active = active or used[ch]
        if used[ch] or v.residues[index].kind == 2: bundle.add(ch)
    if active:
      try: r.residue(v.residues[index], v.books, bundle, pcm)
      except EndOfPacket: break # Vorbis permits a residue to end early.
  for i in countdown(mapping.coupling.high, 0):
    let (mag, angle) = mapping.coupling[i]
    uncouple(pcm[mag], pcm[angle])
  for ch in 0 ..< channels:
    if gains[ch].len == 0:
      pcm[ch].setLen(n)
      zeroMem(addr pcm[ch][0], n * sizeof(float64))
    else:
      for i, gain in gains[ch]: pcm[ch][i] *= gain
      v.plans[int(mode.long)].inverseMdct(v.fftWork, pcm[ch])

  let prev = if v.previous.len > 0: v.previous[0].len else: 0
  let count = if prev == 0: 0 else: (prev + n) div 4
  var first = 0
  var limit = count
  v.nominal += count
  let estimated = if v.granule < 0: v.nominal else: v.granule
  if v.granule >= 0 and v.granule > high(int64) - count:
    invalid("Vorbis granule position overflow.")
  let endPos = estimated + (if v.granule < 0: 0 else: count)
  if packet.granule >= 0:
    let trim = int(clamp(endPos - packet.granule, 0'i64, int64(count)))
    if packet.eos: limit -= trim
    elif v.granule < 0: first = trim
    v.granule = packet.granule
  elif v.granule >= 0:
    v.granule = endPos

  result = AudioFrame(time: float64(v.samples) / float64(v.info.sampleRate),
    channels: channels, sampleRate: v.info.sampleRate,
    samples: newSeq[float32]((limit - first) * channels))
  let overlap = min(prev, n) div 2

  let window = int(2 * overlap != v.sizes[0])
  if overlap > 0 and v.windows[window].len == 0:
    v.windows[window] = initWindow(overlap)
  if first < limit:
    for ch in 0 ..< channels:
      overlapChannel(v.previous[ch], pcm[ch], v.windows[window],
        first, limit, ch, channels, result.samples)
  v.samples += limit - first
  swap(v.previous, v.current)
