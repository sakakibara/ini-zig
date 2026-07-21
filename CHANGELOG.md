# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Document.setValueSegments`: a `.section` value now materializes a whole
  section (`segments.len == 1`) or, under a subsection-quoting dialect, a
  whole subsection (`segments.len == 2`) instead of `error.InvalidValue`.
  Every entry is written under it, in order -- a nested `.string`, `.list`,
  or further `.section` entry each handled exactly as it would be at that
  path directly, so a nested subsection materializes as its own further
  `[section "subsection"]` header. If the target already exists, its entries
  are merged into it (no duplicate header); otherwise a whole new section (or
  subsection) is appended at the end of the document, separated the same way
  a single created key's section already was.
- `Document.removeSegments`: when `segments` names no key line but resolves
  to an existing section or subsection instead, the whole section is removed
  -- every physically distinct block matching it (a section may legitimately
  reappear later in the file as its own separate header under this library's
  default `duplicate_sections = .merge` policy), its entries, and its
  blank-line separator, while a sibling section/subsection and a comment
  documenting a NEIGHBORING section are left untouched.

## [0.4.0] - 2026-07-22

### Added

- `Document.setValueSegments`: set a path from an `ini.Value`, handling both
  a `.string` scalar (dialect-aware escaping, identical to `setSegments`) and
  a `.list` (a multi-value key, e.g. a gitconfig multi-var like
  `remote.origin.fetch` with several refspecs). Setting a `.list` leaves the
  key backed by exactly one `key = item` line per element, in order,
  replacing however many lines it previously had; a missing key is created
  the same way a scalar `set` creates one; an empty list removes the key's
  lines entirely rather than leaving a valueless key behind (a bare
  gitconfig key already means boolean-true, not "zero values"). `.section`
  is `error.InvalidValue`.
- `Document.removeSegments`: now removes EVERY physical line backing a
  multi-value key (`duplicate_keys = .accumulate`, e.g. gitconfig), not just
  the one line the parser's span map happens to still point at. Every other
  dialect's behavior is unchanged.

### Fixed

- `Document`: a key appended into the section that ends the file no longer
  slips into a section created later in the same edit session. Both an
  append into an existing last section and a brand-new appended section
  anchor at end-of-file, so when several edits are batched before `emit`,
  a key issued after a new-section create was emitted after that new block
  and silently landed in the wrong section (dropping it from its own). A
  newly appended section block now always emits after any same-position
  insertion into existing content. Affects both scalar (`set`/`setSegments`)
  and multi-value (`setValueSegments` `.list`) appends.
- `Document.set` / `setLiteral` / `setSegments` / `setLiteralSegments`:
  resolving a path into an existing section under a case-folding dialect
  (`generic`, `gitconfig`, `windows`) now matches a differently-cased
  section name (e.g. `X`) into the already-parsed section (`[x]`) instead of
  appending a case-variant duplicate header that would only merge with it on
  the next re-parse. Subsection names are unaffected -- they are always
  matched case-sensitively, regardless of dialect.
- Repeating an identical `set`/`setLiteral`/`setSegments`/`setLiteralSegments`
  call is now a byte-identical no-op in two cases that previously duplicated
  the edit instead: setting a path an earlier edit in the same session
  already created (a created path never gains a span, so it was invisible to
  every later lookup); and re-setting an existing key whose value was empty
  (a zero-width splice). The latter risked silently turning a scalar value
  into a multi-value list under an accumulating dialect (e.g. gitconfig) on
  a plain repeat.
- `Document.set` / `setLiteral` / `setSegments` / `setLiteralSegments`:
  re-setting a path an earlier edit in the same session already created, to a
  DIFFERENT value, now overwrites that create in place instead of appending a
  second line for the same key. Previously only a byte-identical repeat was
  recognized as a no-op; a differing value fell through to the append path
  and, under an accumulating dialect (e.g. gitconfig), silently turned the
  key's read-back from a scalar into a multi-value list.
- `Document.set` / `setLiteral` / `setSegments` / `setLiteralSegments`:
  resolving a path into an existing KEY under a case-folding dialect
  (`generic`, `gitconfig`, `windows`) now matches a differently-cased key
  name (e.g. `AUTOCRLF`) into the already-stored key (`autocrlf`) instead of
  appending a case-variant duplicate line that would only merge with it --
  and, under an accumulating dialect, turn a scalar into a list -- on the
  next re-parse. This mirrors the section-name case fold already applied;
  subsection names remain unaffected, always matched case-sensitively
  regardless of dialect.
- `Document.setSegments` / `setLiteralSegments` / `setValueSegments`:
  re-setting a path an earlier edit in the same session already created, as
  the OTHER kind (a scalar create re-set as a `.list`, or vice versa), now
  collapses onto that create in place instead of appending a second,
  duplicate backing for the same path. Previously the two creates were
  tracked in separate bookkeeping that never consulted each other, so the
  prior lines were left behind and the new kind's lines were appended
  alongside them; an empty-list re-set of a scalar create is now a removal
  (matching how an empty-list re-set of an existing key already behaves)
  instead of a silent no-op that left the stale line in place. A path is
  now always tracked under exactly one kind, so a further re-set (of either
  kind) still finds and rewrites the same splice.
- `Document.set` / `setLiteral` / `setSegments` / `setLiteralSegments` /
  `setValueSegments` (`.string`): setting a scalar on a key that already has
  several in-source occurrences (a multi-value key under an accumulating
  dialect, e.g. a gitconfig multi-var like repeated `fetch =` lines) now
  collapses the key to exactly that one value, at the first occurrence's
  position, removing every other occurrence. Previously only the last
  occurrence was spliced in place, leaving the key's other lines stale and
  the read-back a list instead of the intended scalar. A key with a single
  occurrence is unaffected.
- `Document.remove` / `set` / `setLiteral` (the dotted-STRING path API):
  addressing a gitconfig subsection whose own name contains a `.` (e.g.
  `branch.feature.x.merge` for `[branch "feature.x"]`) no longer resolves the
  wrong container. The dotted string over-segments into more parts than the
  dialect's section/subsection/key shape has, and the multi-occurrence
  scanner used to reconstruct a truncated container from those parts (e.g.
  the bare `[branch]` section instead of the `"feature.x"` subsection),
  either missing the path entirely (`error.PathNotFound`) or editing a
  same-named key in the wrong section. Such an over-segmented path now falls
  back to the single anchor its raw dotted span resolves to, matching how it
  already worked before multi-occurrence scanning was added. The
  segments-array API (e.g. `&.{"branch", "feature.x", "merge"}`), which
  addresses the subsection as its own segment, is unaffected and continues
  to scan every occurrence correctly.

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
