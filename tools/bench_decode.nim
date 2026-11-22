## Build this driver against each source tree, then run the Nim-backed binary
## with the C-backed binary's path as its only argument.
import std/[algorithm, json, monotimes, os, osproc, strformat, strutils, times]
import ogg

const
  DataDir = currentSourcePath().parentDir.parentDir / "tests" / "data"
  BatchNs = 125_000_000
  Rounds = 8
  Corpus = "All fixtures"

type
  Output = object
    sampleFrames, videoFrames: int
  Fixture = object
    name, data: string
    expected: Output

proc decode(data: string): Output =
  ## Opens from memory and consumes all owned frames through clean EOF.
  let decoder = newOgg(data)
  defer: decoder.close()
  var frame: MediaFrame
  while decoder.readFrame(frame):
    case frame.kind
    of Audio:
      result.sampleFrames += frame.audio.samples.len div frame.audio.channels
    of Video:
      inc result.videoFrames

proc measure(fixtures: openArray[Fixture]): float64 =
  ## Times warm, complete passes and returns milliseconds per pass.
  var count = 0
  var elapsed: int64
  for f in fixtures:
    if decode(f.data) != f.expected:
      raise newException(ValueError, "Unexpected output counts for " & f.name)
  let start = getMonoTime()
  while elapsed < BatchNs:
    for f in fixtures:
      if decode(f.data) != f.expected:
        raise newException(ValueError, "Unexpected output counts for " & f.name)
    inc count
    elapsed = (getMonoTime() - start).inNanoseconds
  elapsed.float64 / (1_000_000 * count).float64

proc sample(): JsonNode =
  ## Preloads the manifest corpus and measures each file and a full suite pass.
  var fixtures: seq[Fixture]
  for entry in parseFile(DataDir / "manifest.json")["cases"]:
    let name = entry["file"].getStr
    fixtures.add(Fixture(name: name, data: readFile(DataDir / name),
      expected: Output(sampleFrames: entry{"samples"}.getInt,
        videoFrames: entry{"frames"}.getInt)))
  result = newJObject()
  for i, f in fixtures:
    result[f.name] = %measure(fixtures.toOpenArray(i, i))
  result[Corpus] = %measure(fixtures)

proc runSample(exe: string): JsonNode =
  ## Collects one independent timing batch from a release-built worker.
  let p = startProcess(exe, args = ["--sample"], options = {poStdErrToStdOut})
  defer: p.close()
  var output = ""
  for line in p.lines: output.add(line & "\n")
  if p.waitForExit() != 0:
    raise newException(ValueError, "Benchmark worker failed.\n" & output)
  parseJson(output)

proc median(batches: seq[JsonNode], name: string): float64 =
  ## Returns the median batch mean for one workload.
  var values: seq[float64]
  for batch in batches: values.add(batch[name].getFloat)
  values.sort()
  (values[(values.len - 1) div 2] + values[values.len div 2]) / 2

proc main() =
  ## Alternates backend order and reports elapsed milliseconds per decode.
  when not defined(release):
    quit("Build the benchmark with -d:release.")
  if paramCount() != 1:
    quit("Usage: bench-nim <path-to-bench-c>")
  if paramStr(1) == "--sample":
    echo sample()
    return
  let cExe = absolutePath(paramStr(1))
  var cBatches, nimBatches: seq[JsonNode]
  for i in 0 ..< Rounds:
    if i mod 2 == 0:
      cBatches.add(runSample(cExe))
    nimBatches.add(runSample(getAppFilename()))
    if i mod 2 != 0:
      cBatches.add(runSample(cExe))
  echo "| Fixture | C (ms) | Nim (ms) | Nim time / C time |"
  echo "|---|---:|---:|---:|"
  for name in nimBatches[0].keys:
    let c = cBatches.median(name)
    let native = nimBatches.median(name)
    echo &"| {name} | {c:.4f} | {native:.4f} | {native / c:.2f}x |"

main()
