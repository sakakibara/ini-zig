# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-07-21

### Added

- `Document.empty`: bootstrap a document with no source bytes at all, for a
  config layer that may not exist on disk yet. The first edit creates the
  whole requested section and key.
- `Document.setSegments` / `setLiteralSegments` / `removeSegments`: address a
  path as pre-split segments instead of a dotted string, so a section or key
  name containing a literal `.` (e.g. a gitconfig subsection) is addressed
  unambiguously. `set` / `setLiteral` / `remove` now split a dotted string
  into segments the same way internally, so a dot-free path behaves
  identically either way.

### Changed

- `Document.set` / `setLiteral` / `setSegments` / `setLiteralSegments` now
  CREATE a missing section (or, under a subsection-quoting dialect, a
  missing subsection) instead of returning `error.PathNotFound`: a whole new
  `[section]` or `[section "subsection"]` header plus the key is appended at
  the end of the document, one blank line after prior content. A missing key
  in an existing section is appended to it. This is the one intentional
  behavior change; every other case (an existing path, a genuinely over-deep
  path, a container segment that already names a non-section value) is
  unchanged. The new-key/new-section collision guard folds names the same
  way the parser would store them, so a case-only collision under a
  case-folding dialect is rejected instead of silently shadowing the
  existing section on re-parse; appended lines and separators mirror the
  source's line terminator, so a CRLF document stays CRLF instead of picking
  up mixed line endings or a doubled blank line; and a section name is only
  rejected for edge whitespace when the dialect would actually trim it away,
  so `[ s ]` remains creatable under a dialect (e.g. `generic`) that keeps
  section-name whitespace significant.

## [0.2.0] - 2026-07-05

### Added

- `EmitOptions.sort_keys`: opt-in, default `false`. When set, `encode` and
  `encodeTyped` emit each section's key/value pairs, and the sections
  themselves, in ascending byte-lexicographic order, recursively. Ordering
  only, not canonicalization (not JCS): default output stays byte-for-byte
  unchanged.

## [0.1.1] - 2026-07-05

### Fixed

- 32-bit targets now compile. `u64` span offsets are cast to `usize` at
  slice-indexing and loop-index sites that failed to build where `usize`
  is 32-bit (e.g. `wasm32-wasi`). No API or behavior change on 64-bit
  targets.

## [0.1.0] - 2026-07-03

Initial release. Dialect-aware INI parser, typed codec, lossless document
model, reader-backed streaming, and diagnostics.

### Added

- Dialect-aware parser: five runtime-configurable presets (generic, gitconfig,
  systemd, windows, strict) covering the main INI families. Every structural
  decision -- comment chars, separator chars, duplicate-key and
  duplicate-section policy, case folding, subsection nesting, line
  continuation, quoting -- is driven by the runtime `Dialect` struct.
  Custom dialects are built by starting from a preset and overriding fields.
- Typed codec: `parseInto` / `decode` / `encodeTyped` via comptime reflection
  over structs, slices, arrays, optionals, and enums (by tag name), with an
  `ignore_unknown_fields` escape hatch.
- Encoding: `encode` (Value-based) and `encodeTyped` (comptime-typed),
  controlled by `EmitOptions`.
- Lossless document model: `Document.parse` keeps source bytes; emit is
  byte-identical when unmodified and minimal-diff after `set` /
  `setLiteral` / `remove` / comment edits (`addCommentBefore`,
  `setTrailingComment`).
- Reader-backed streaming: `EventReader` yields one `Event` (section header,
  key/value, comment) at a time with a bounded sliding buffer, holding one
  logical line at a time (capped by `ParseOptions.max_line_len`).
  `materialize` composes the entire remaining stream into a `Value` and is
  called before draining events. `ValueStream` iterates sections as complete
  `Value` trees with per-section arena reset for bounded total memory.
- Byte-precise source spans (opt-in via `ParseOptions.spans`): each span is
  a `{ start, end }` pair of `u64` byte offsets addressing inputs of any
  size, keyed by dotted path. Derive 1-indexed line/column on demand with
  `Span.lineCol(src)`; `Diagnostic.render` takes the source bytes to render
  location.
- Multi-error diagnostics: one pass collects every parse error with recovery,
  rendered one-line via `Diagnostic.render` or rustc-style via
  `Diagnostic.renderRich`, with "did you mean" suggestions driven by
  Levenshtein distance.
- Conformance: an authored multi-dialect corpus (`tests/corpus/`) covers
  generic, gitconfig, systemd, and windows fixture families; the corpus is
  enforced in `zig build test`. A differential harness
  (`tools/run_differential.sh`) compares ini-zig output against Python
  `configparser` (generic dialect) and `git config --list` (gitconfig
  dialect) as reference oracles.
- Memory model: all values are arena-allocated; deinit the arena to free
  the whole tree. All internal offsets and stored spans are `u64`, so inputs
  of any size are handled with no 4 GiB cap.
- Tooling: random-input fuzzer (`zig build fuzz`), microbenchmarks
  (`zig build bench`), generated reference docs (`zig build docs`), and
  runnable examples (`basic`, `typed`, `edit`, `spans`, `stream`, `dialects`).

[Unreleased]: https://github.com/sakakibara/ini-zig/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/sakakibara/ini-zig/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/sakakibara/ini-zig/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sakakibara/ini-zig/releases/tag/v0.1.0
