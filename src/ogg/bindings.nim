import std/os

const
  Root = currentSourcePath().parentDir
  Vendor = Root / "vendor"
  Header = Root / "reference.h"

{.passC: "-I" & quoteShell(Root).}
{.passC: "-I" & quoteShell(Vendor / "ogg/include").}
{.passC: "-I" & quoteShell(Vendor / "vorbis/include").}
{.passC: "-I" & quoteShell(Vendor / "theora/include").}
when not defined(windows):
  {.passC: "-DHAVE_ALLOCA_H".}
  {.passL: "-lm".}

{.compile: Vendor / "ogg/src/bitwise.c".}
{.compile: Vendor / "ogg/src/framing.c".}
{.compile: Vendor / "vorbis/lib/mdct.c".}
{.compile: Vendor / "vorbis/lib/smallft.c".}
{.compile: Vendor / "vorbis/lib/block.c".}
{.compile: Vendor / "vorbis/lib/envelope.c".}
{.compile: Vendor / "vorbis/lib/window.c".}
{.compile: Vendor / "vorbis/lib/lsp.c".}
{.compile: Vendor / "vorbis/lib/lpc.c".}
{.compile: Vendor / "vorbis/lib/analysis.c".}
{.compile: Vendor / "vorbis/lib/synthesis.c".}
{.compile: Vendor / "vorbis/lib/psy.c".}
{.compile: Vendor / "vorbis/lib/info.c".}
{.compile: Vendor / "vorbis/lib/floor1.c".}
{.compile: Vendor / "vorbis/lib/floor0.c".}
{.compile: Vendor / "vorbis/lib/res0.c".}
{.compile: Vendor / "vorbis/lib/mapping0.c".}
{.compile: Vendor / "vorbis/lib/registry.c".}
{.compile: Vendor / "vorbis/lib/codebook.c".}
{.compile: Vendor / "vorbis/lib/sharedbook.c".}
{.compile: Vendor / "vorbis/lib/lookup.c".}
{.compile: Vendor / "vorbis/lib/bitrate.c".}
{.compile: Vendor / "theora/lib/apiwrapper.c".}
{.compile: Vendor / "theora/lib/bitpack.c".}
{.compile: Vendor / "theora/lib/decapiwrapper.c".}
{.compile: Vendor / "theora/lib/decinfo.c".}
{.compile: Vendor / "theora/lib/decode.c".}
{.compile: Vendor / "theora/lib/dequant.c".}
{.compile: Vendor / "theora/lib/fragment.c".}
{.compile: Vendor / "theora/lib/huffdec.c".}
{.compile: Vendor / "theora/lib/idct.c".}
{.compile: Vendor / "theora/lib/info.c".}
{.compile: Vendor / "theora/lib/internal.c".}
{.compile: Vendor / "theora/lib/quant.c".}
{.compile: Vendor / "theora/lib/state.c".}
{.compile: Root / "reference.c".}

type
  Reference* {.importc: "ogg_reference", header: Header,
      incompleteStruct.} = object

  ReferenceInfo* {.importc: "ogg_reference_info", header: Header,
      bycopy.} = object
    channels*, sample_rate*: cint
    width*, height*, offset_x*, offset_y*, pixel_format*: cint
    fps_numerator*, fps_denominator*: cuint

  ReferenceFrame* {.importc: "ogg_reference_frame", header: Header,
      bycopy.} = object
    kind*, samples*: cint
    time*: cdouble
    pcm*: ptr UncheckedArray[ptr UncheckedArray[cfloat]]
    planes*: array[3, ptr UncheckedArray[uint8]]
    widths*, heights*, strides*: array[3, cint]

proc referenceOpen*(data: pointer, length: csize_t): ptr Reference
    {.importc: "ogg_reference_open", header: Header, cdecl, raises: [].}
  ## Opens the reference backend, borrowing the input until close.

proc referenceError*(decoder: ptr Reference): cstring
    {.importc: "ogg_reference_error", header: Header, cdecl, raises: [].}
  ## Returns nil on success or the first decoder error.

proc referenceInfo*(decoder: ptr Reference): ReferenceInfo
    {.importc: "ogg_reference_get_info", header: Header, cdecl, raises: [].}
  ## Copies metadata discovered in the codec headers.

proc referenceRead*(decoder: ptr Reference, frame: ptr ReferenceFrame): cint
    {.importc: "ogg_reference_read", header: Header, cdecl, raises: [].}
  ## Borrows one decoded frame, returning one, zero for EOF, or minus one.

proc referenceClose*(decoder: ptr Reference)
    {.importc: "ogg_reference_close", header: Header, cdecl, raises: [].}
  ## Releases a reference decoder and its codec contexts.
