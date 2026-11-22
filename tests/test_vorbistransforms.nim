import std/[complex, math, unittest]
import ogg/vorbistransforms

suite "Vorbis inverse transform":
  test "all block sizes agree with the cosine definition":
    var plan: MdctPlan
    var work: seq[Complex64]
    for size in [64, 128, 256, 512, 1024, 2048, 4096, 8192]:
      let bins = [0, 1, size div 4, size div 2 - 1]
      let weights = [0.25, -0.5, 0.75, 1.0]
      var samples = newSeq[float64](size div 2)
      for i, bin in bins: samples[bin] = weights[i]
      plan.inverseMdct(work, samples)
      require samples.len == size
      for t, actual in samples:
        let phase = 2 * PI / float64(size) * (float64(t + size div 4) + 0.5)
        var expected = 0.0
        for i, bin in bins:
          expected += weights[i] * cos(phase * (float64(bin) + 0.5))
        check abs(actual - expected) < 1e-9

  test "dense spectra exercise every butterfly input":
    var plan: MdctPlan
    var work: seq[Complex64]
    var noise = 0xA525'u32
    for size in [64, 128, 256, 512, 1024, 2048, 4096, 8192]:
      var spectrum = newSeq[float64](size div 2)
      for x in spectrum.mitems:
        noise = noise * 1664525 + 1013904223
        x = float64(cast[int32](noise)) / 2147483648.0
      var samples = spectrum
      plan.inverseMdct(work, samples)
      for t in [0, 1, size div 4, size div 2 - 1, size - 1]:
        let phase = 2 * PI * (float64(t + size div 4) + 0.5) / float64(size)
        var expected = 0.0
        for i, x in spectrum: expected += x * cos(phase * (float64(i) + 0.5))
        check abs(samples[t] - expected) < 1e-8
