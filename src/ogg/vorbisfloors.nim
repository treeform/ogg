import std/[algorithm, math]
import bitstreams, vorbisbooks

type
  FloorClass = object
    size, bits, master: int
    books: array[8, int]

  Floor* = object
    kind, order, rate, barkMap, ampBits, ampOffset: int
    books, partitions: seq[int]
    classes: seq[FloorClass]
    multiplier: int
    x, sorted, low, high: seq[int]

proc bookIndex*(r: var BitReader, books: seq[Book], optional = false): int =
  ## Reads and validates a setup-header codebook reference.
  result = r.read(8) - int(optional)
  if result >= books.len:
    invalid("Invalid Vorbis codebook index.")

proc readFloor*(r: var BitReader, books: seq[Book]): Floor =
  ## Reads either Bark-scale LSP or piecewise linear floor configuration.
  result.kind = r.read(16)
  if result.kind == 0:
    result.order = r.read(8)
    result.rate = r.read(16)
    result.barkMap = r.read(16)
    result.ampBits = r.read(6)
    result.ampOffset = r.read(8)
    if min(result.order, min(result.rate, result.barkMap)) == 0:
      invalid("Invalid Vorbis floor 0 parameters.")
    for i in 0 .. r.read(4):
      let index = r.bookIndex(books)
      if books[index].lookup == 0:
        invalid("Missing floor 0 vector lookup.")
      result.books.add(index)
    return
  if result.kind != 1:
    invalid("Unsupported Vorbis floor type.")
  var lastClass = -1
  for i in 0 ..< r.read(5):
    let group = r.read(4)
    result.partitions.add(group)
    lastClass = max(lastClass, group)
  for i in 0 .. lastClass:
    var c = FloorClass(size: r.read(3) + 1, bits: r.read(2))
    if c.bits > 0:
      c.master = r.bookIndex(books)
    for j in 0 ..< 1 shl c.bits:
      c.books[j] = r.bookIndex(books, true)
    result.classes.add(c)
  result.multiplier = r.read(2) + 1
  let bits = r.read(4)
  result.x = @[0, 1 shl bits]
  result.low = @[0, 0]
  result.high = @[0, 0]
  for group in result.partitions:
    for j in 0 ..< result.classes[group].size:
      let x = r.read(bits)
      var lo = 0
      var hi = 1
      for k, earlier in result.x:
        if earlier == x: invalid("Duplicate Vorbis floor coordinate.")
        if earlier < x and earlier > result.x[lo]: lo = k
        if earlier > x and earlier < result.x[hi]: hi = k
      result.x.add(x)
      result.low.add(lo)
      result.high.add(hi)
  for i in 0 ..< result.x.len:
    result.sorted.add(i)
  let xs = result.x
  result.sorted.sort(proc(a, b: int): int = cmp(xs[a], xs[b]))

proc bark(hz: float64): float64 =
  ## Maps frequency to the critical-band scale used by floor 0.
  13.1 * arctan(0.00074 * hz) + 2.24 * arctan(1.85e-8 * hz * hz) + 1e-4 * hz

proc floorZero(r: var BitReader, f: Floor, books: seq[Book], n: int): seq[float64] =
  ## Evaluates the decoded line spectral pairs on the Bark frequency grid.
  var amp = 0.0
  var shift = 0
  while shift < f.ampBits:
    let take = min(24, f.ampBits - shift)
    amp += float64(r.read(take)) * pow(2.0, float64(shift))
    shift += take
  if amp == 0: return
  let choice = r.read(ilog(f.books.len))
  if choice >= f.books.len: invalid("Invalid floor 0 book.")
  let book = books[f.books[choice]]
  var lsp: seq[float64]
  var last = 0.0
  while lsp.len < f.order:
    let entry = r.scalar(book)
    for value in book.vector(entry):
      lsp.add(value + last)
      if lsp.len == f.order: break
    last = lsp[^1]
  for a in lsp.mitems: a = 2 * cos(a)
  amp *= float64(f.ampOffset) / (pow(2.0, float64(f.ampBits)) - 1)
  let nyquist = 0.5 * float64(f.rate)
  let scale = float64(f.barkMap) / bark(nyquist)
  result.setLen(n)
  for i in 0 ..< n:
    let bin = floor(bark(nyquist * float64(i) / float64(n)) * scale)
    let w = 2 * cos(PI * bin / float64(f.barkMap))
    var p = 0.5
    var q = 0.5
    for j in countup(1, f.order - 1, 2):
      q *= w - lsp[j - 1]
      p *= w - lsp[j]
    if (f.order and 1) != 0:
      q *= w - lsp[^1]
      p *= p * (4 - w*w)
      q *= q
    else:
      p *= p * (2 - w)
      q *= q * (2 + w)
    result[i] = exp((amp / sqrt(p + q) - float64(f.ampOffset)) * ln(10.0) / 20)

proc predict(x0, y0, x1, y1, x: int): int =
  ## Interpolates a floor post with truncation towards zero.
  y0 + (y1 - y0) * (x - x0) div (x1 - x0)

const Amplitude = block:
  var table: array[256, float64]
  for i in 0 .. 255:
    table[i] = exp(float64(i - 255) * (140.0 / 256) * ln(10.0) / 20)
  table

proc decodeFloor*(r: var BitReader, f: Floor, books: seq[Book], n: int): seq[float64] =
  ## Reconstructs spectral gains, with an empty sequence for an unused channel.
  if f.kind == 0: return r.floorZero(f, books, n)
  if not r.flag(): return
  let limit = [256, 128, 86, 64][f.multiplier - 1]
  var
    y = newSeq[int](f.x.len)
    active = newSeq[bool](f.x.len)
    index = 2
  for i in 0 .. 1:
    y[i] = r.read(ilog(limit - 1))
    if y[i] >= limit: invalid("Invalid Vorbis floor amplitude.")
    active[i] = true
  for group in f.partitions:
    let c = f.classes[group]
    var selector = if c.bits > 0: r.scalar(books[c.master]) else: 0
    for j in 0 ..< c.size:
      let book = c.books[selector and ((1 shl c.bits) - 1)]
      selector = selector shr c.bits
      let value = if book >= 0: r.scalar(books[book]) else: 0
      let lo = f.low[index]
      let hi = f.high[index]
      let mid = predict(f.x[lo], y[lo], f.x[hi], y[hi], f.x[index])
      let room = 2 * min(mid, limit - mid)
      if value == 0:
        y[index] = mid
      else:
        active[lo] = true
        active[hi] = true
        active[index] = true
        if value >= room:
          y[index] = if limit - mid > mid: value else: limit - 1 - value
        elif (value and 1) != 0:
          y[index] = mid - ((value + 1) shr 1)
        else:
          y[index] = mid + (value shr 1)
        if y[index] notin 0 ..< limit: invalid("Invalid Vorbis floor amplitude.")
      inc index
  result.setLen(n)
  var prev = 0
  for point in f.sorted:
    if point != 0 and active[point]:
      for x in f.x[prev] ..< min(n, f.x[point]):
        let value = predict(f.x[prev], y[prev] * f.multiplier,
          f.x[point], y[point] * f.multiplier, x)
        result[x] = Amplitude[value]
      prev = point
  for x in f.x[prev] ..< n:
    result[x] = Amplitude[y[prev] * f.multiplier]

