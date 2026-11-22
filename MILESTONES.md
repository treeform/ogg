# Milestones

## 1. Reference wrappers and a small corpus

The baseline is implemented. Cross-platform CI is the acceptance check.

- [x] Inspect treeform/mpeg and treeform/slappy for Nim wrappers and test patterns.
- [x] Pin and vendor libogg 1.3.6, libvorbis 1.3.7, and libtheora 1.2.0.
- [x] Preserve source URLs, release hashes, and upstream licenses.
- [x] Decode audio-only, video-only, and multiplexed files through a Nim facade.
- [x] Return owned float PCM and YCbCr planes with metadata and timestamps.
- [x] Generate eight small, redistributable test files with reproducible recipes.
- [x] Compare every sample and visible video plane against FFmpeg's native decoders.
- [x] Check channel order, sample counts, frame counts, timestamps, and EOF.
- [x] Test corruption, truncation, page sequence gaps, continuation, and lifecycle.
- [x] Add Linux, macOS, and Windows CI and the standard API docs workflow.

Acceptance commands:

```sh
python tools/gen_media.py --verify
nim r tests/tests.nim
nim r -d:release tests/tests.nim
```

The corpus is deliberately small. Passing it establishes the reference baseline,
not complete Vorbis or Theora conformance. No native codec implementation is
claimed by this milestone.

## 2. Native Ogg container

- [ ] Implement page headers, CRC, lacing, packet assembly, and stream serials.
- [ ] Add differential tests against libogg, including boundary and invalid cases.
- [ ] Define resource limits, incremental input, chaining, and granule semantics.
- [ ] Feed native-demuxed packets into the existing reference codec decoders.

## 3. Native Vorbis audio

- [ ] Port header parsing, bit reading, codebooks, floors, and residues.
- [ ] Port channel coupling, inverse MDCT, windowing, and overlap-add.
- [ ] Preserve exact granule trimming and document multichannel order.
- [ ] Expand the corpus for floor 0, transients, variable blocks, and 5.1 audio.
- [ ] Compare PCM, performance, and memory use against the C reference.

## 4. Native Theora video

- [ ] Port headers, Huffman tables, frame reconstruction, and inverse transforms.
- [ ] Port motion compensation, loop filtering, and reference frame management.
- [ ] Cover duplicate frames, keyframes, cropping offsets, and granule positions.
- [ ] Compare all decoded planes against the C reference and independent decoder.

## Later

Streaming input, seeking, chaining, broader conformance vectors, fuzzing,
benchmarks, and integration with mpeg-style players and slappy audio output.
