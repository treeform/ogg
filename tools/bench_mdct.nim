## Isolates inverse MDCT time, excluding codec parsing and allocation setup.
import std/[complex, monotimes, times, strformat]
import ogg/vorbistransforms
var checksum = 0.0
for size in [256, 1024, 4096]:
  var plan: MdctPlan
  var work: seq[Complex64]
  var samples = newSeq[float64](size div 2)
  for i in 0 ..< samples.len: samples[i] = float64(i mod 17) / 17
  plan.inverseMdct(work, samples)
  let start = getMonoTime()
  const iterations = 20000
  for pass in 0 ..< iterations:
    samples.setLen(size div 2)
    for i in 0 ..< samples.len: samples[i] = float64(i mod 17) / 17
    plan.inverseMdct(work, samples)
    checksum += samples[pass mod size]
  let ns = (getMonoTime() - start).inNanoseconds.float64 / iterations
  echo &"{size}: {ns:.1f} ns/MDCT"
echo checksum
