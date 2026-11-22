# Reference implementation

## Why these libraries

`treeform/mpeg` bundles PL_MPEG, then exposes an ergonomic Nim wrapper with owned
frames, explicit cleanup, and independent FFmpeg comparisons. `treeform/slappy`
uses a bundled stb_vorbis decoder for audio loading. This project follows those
integration patterns, using Xiph's codec implementations as the porting reference.

The local slappy snapshot uses stb_vorbis 1.10, whose header documents limitations
including floor 0, initial sample trimming, and chaining. Libvorbis provides the
full reference codec implementation for studying those details. The wrapper in
this project still deliberately rejects chaining and unsupported logical streams.

| Layer | Pinned reference | Main source entry points |
| --- | --- | --- |
| Ogg container | libogg 1.3.6 | `src/framing.c`, `src/bitwise.c` |
| Vorbis audio | libvorbis 1.3.7 | `lib/info.c`, `synthesis.c`, `block.c` |
| Vorbis transforms | libvorbis 1.3.7 | `codebook.c`, `floor0.c`, `floor1.c`, `res0.c`, `mapping0.c`, `mdct.c` |
| Theora video | libtheora 1.2.0 | `lib/decinfo.c`, `decode.c`, `state.c` |
| Theora reconstruction | libtheora 1.2.0 | `huffdec.c`, `dequant.c`, `idct.c`, `fragment.c` |

The complete upstream release URLs and SHA-256 values are in
[`sources.json`](../tests/reference/vendor/sources.json). Checksums come from
[Xiph's download page](https://xiph.org/downloads/). `python tools/vendor.py`
downloads and verifies those releases before extracting the selected sources.

## Native decoder

`import ogg` builds the container reader and both codecs from Nim source.
`src/ogg/packets.nim` validates each page and assembles packets across pages.
`vorbis.nim` synthesizes interleaved PCM in Vorbis channel order. `theora.nim`
reconstructs the full coded YCbCr planes and retains the reference pictures
needed for later frames. Both decoders return owned data.

Input occupies one in-memory string. The reader tracks up to two logical
streams and validates checksums before emitting packets. Vorbis setup limits
the combined count of codebook entries and packed lookup values to 8,388,608.
The existing limits of eight audio channels, 384000 Hz and 4096 by 4096 coded
pixels apply at the identification headers.

## Reference build and ABI

`tests/reference/bindings.nim` compiles the portable C source files directly. Architecture
specific assembly, external codec DLLs, and external build systems are not used.
Libvorbis's shared synthesis sources also refer to some analysis routines, so the
linked dependency set contains those routines even though no encoder is exposed.

The source snapshot retains top-level library C and header files for study.
Only the source list in `bindings.nim` is compiled. It is not a standalone build
of the upstream encoder packages, which also need omitted generated codebooks
and build files.

Upstream files remain unmodified. One added build adaptation,
`vendor/ogg/include/ogg/config_types.h`, supplies the standard fixed-width types
normally written by configure on Unix. Windows and macOS use upstream type paths.
Unix builds define `HAVE_ALLOCA_H` and link the math library. Theora's portable C
path is selected by leaving its assembly feature macros unset.

`reference.c` keeps upstream structure layouts behind a small C ABI. Its input
buffer is borrowed from a Nim-owned string. It validates page sequencing, dispatches
logical streams, consumes the three codec headers, and emits one decoded packet's
output at a time. It does not buffer decoded audio or video for the other stream.

`tests/test_reference.nim` compares this borrowed output with each frame from
the public decoder. It checks frame order, timestamps, sample counts, absolute
PCM error below 0.00001, every byte of all three padded planes, and EOF.
Run `nim r tests/test_reference.nim path/to/clip.ogv` to compare another file.

## Benchmarking the corpus

Build `tools/bench_decode.nim` twice with the same release flags. Point one
build at the original C-backed API from commit `ba3a2e6` and the other at the
current Nim implementation. Create `tmp/bench/baseline` before running these
commands from the repository root.

```sh
git archive -o tmp/bench/baseline.tar ba3a2e6 src
tar -xf tmp/bench/baseline.tar -C tmp/bench/baseline
nim c -d:release -d:benchOriginalC '--path:$projectDir/../tmp/bench/baseline/src' --nimcache:tmp/bench/cache-c --out:tmp/bench/bench-c tools/bench_decode.nim
nim c -d:release '--path:$projectDir/../src' --nimcache:tmp/bench/cache-native --out:tmp/bench/bench-nim tools/bench_decode.nim
./tmp/bench/bench-nim ./tmp/bench/bench-c
```

On Windows, give both executables the `.exe` extension in the build and run
commands. Each timed pass opens preloaded input, decodes to owned frames,
checks output counts, and closes the decoder. Each row reports the median of
eight warm batch means, alternating which implementation runs first. The
whole-corpus row times one decode of every manifest entry per pass.

To capture a Fluffy trace, put `fluffy/measure` and its `jsony` dependency on
Nim's search path. Build the native benchmark with `-d:release -d:oggFluffy`
and run it with `--trace tmp/bench/decode.json`. The trace covers three passes
over the same preloaded corpus. Use the ordinary release builds for the timing
table so trace collection is outside the measurement.

On x86-64 the decoder selects its AVX2 kernels at runtime when the processor
and OS support them. Build the same source with `-d:oggNoSimd` to benchmark or
test the portable scalar path. AVX2 flags apply only to the kernel module.

## Timing and pixels

Vorbis synthesis performs granule-based end trimming. Audio timestamps count
returned sample frames, starting at zero. Theora timestamps count decoded frames
using the rational frame rate, also starting at zero. This baseline is for complete
streams decoded from their beginning. It does not preserve nonzero absolute
stream offsets or support seeking into spliced streams.

Video planes include the coded border. `VideoInfo` records the visible size and
offsets. Postprocessing is disabled for reproducible plane comparisons. `rgba`
is a convenience conversion with a fixed limited-range BT.601 matrix and nearest
chroma sampling, not a color-managed renderer.

Duplicate Theora packets repeat the previous picture and advance its timestamp.
The tests exercise duplicates by appending an empty packet to a corpus file.

## Specifications

- [Ogg framing and multiplexing](https://xiph.org/ogg/doc/)
- [Vorbis I specification](https://xiph.org/vorbis/doc/)
- [Theora specification and API](https://www.xiph.org/theora/)

## Licenses

The Nim facade and C integration code use this repository's MIT license.
The Vorbis and Theora ports retain the Xiph notices and redistribution terms in
`src/ogg/licenses`. Each vendored library retains its upstream COPYING file.
The generated corpus has its own CC0 dedication in `tests/data/LICENSE`.
