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
[`sources.json`](../src/ogg/vendor/sources.json). Checksums come from
[Xiph's download page](https://xiph.org/downloads/). `python tools/vendor.py`
downloads and verifies those releases before extracting the selected sources.

## Build and ABI

`src/ogg/bindings.nim` compiles the portable C source files directly. Architecture
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

`decoders.nim` copies the borrowed PCM or YCbCr output into Nim sequences before
the next C call. A destructor and an idempotent `close` release native resources.
All public decode and IO failures use `OggError`.

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

Theora duplicates are returned as frames when the decoder reports them. The first
corpus does not yet exercise duplicate-only packets or nonzero crop offsets.

## Native port strategy

Keep this backend and its fixtures intact as an oracle. First separate the native
Ogg packet reader from codec decoding, then replace Vorbis and Theora independently.
The public owned frame types need not expose either backend's ABI.

Compare integer page and packet results exactly. Compare floating audio with
documented tolerances and integer video planes before any RGB conversion. Expand
the corpus before claiming coverage of a new feature.

## Specifications

- [Ogg framing and multiplexing](https://xiph.org/ogg/doc/)
- [Vorbis I specification](https://xiph.org/vorbis/doc/)
- [Theora specification and API](https://www.xiph.org/theora/)

## Licenses

The Nim facade and C integration code use this repository's MIT license. Each
vendored library retains its upstream COPYING file and copyright notices. The
generated corpus has its own CC0 dedication in `tests/data/LICENSE`.
