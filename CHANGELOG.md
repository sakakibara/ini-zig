# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  `Span.lineCol(src)`; `Diagnostic.format` takes the source bytes to render
  location.
- Multi-error diagnostics: one pass collects every parse error with recovery,
  rendered one-line or rustc-style via `Diagnostic.formatRich` with
  "did you mean" suggestions driven by Levenshtein distance.
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

[Unreleased]: https://github.com/sakakibara/ini-zig/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/sakakibara/ini-zig/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sakakibara/ini-zig/releases/tag/v0.1.0
