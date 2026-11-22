# Working on ogg

Follow the Nim project layout and metadata conventions from
[treeform/aistuff](https://github.com/treeform/aistuff), especially PROJECT.md.

- Keep data flat and control flow explicit. Use free procedures and simple types.
- Use two spaces, camelCase procedures and variables, PascalCase types and constants.
- Group imports and adjacent declarations. Keep lines near 80 columns.
- Document procedures with short complete sentences.
- Use OggError at public parsing and IO boundaries and explicit raises effects.
- Keep the public API independent of the C reference backend.
- Keep upstream sources unmodified. Record deliberate build adaptations in
  docs/reference.md and preserve all upstream licenses.
- Do not replace the reference oracle when implementing a native Nim decoder.
- Test samples must include provenance, redistribution terms, generation recipes,
  expected metadata, and hashes. Never add media of uncertain origin.
- Run `nim r tests/tests.nim` after changes. Use `nim r -d:release tests/tests.nim`
  for decoder or buffer changes. Do not rely on runtime checks in release builds.
- Run `python tools/gen_media.py --verify` before committing fixture changes.
- Use Nimby for dependencies and Nim for tests. Keep commits short and descriptive.
- Keep README edits to spelling and grammar unless explicitly requested otherwise.

The initial implementation is a reference wrapper. Native Ogg parsing, Vorbis
decoding, and Theora decoding are separate later milestones in MILESTONES.md.
