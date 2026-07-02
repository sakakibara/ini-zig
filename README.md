# ini

A dialect-aware INI parser for Zig.

- **Dialect-aware** - five built-in presets (generic, gitconfig, systemd, windows, strict),
  all axes runtime-configurable: comment chars, separator chars, duplicate-key and
  duplicate-section policy, case folding, subsection nesting, line continuation, quoting.
- **Typed decoding** - `parseInto(Config, arena, src, .{})` deserializes straight into your
  Zig struct via comptime reflection. No codegen.
- **Lossless document model** - edit an INI file in place; comments, whitespace, and key
  ordering preserved. Unmodified documents emit byte-identical output; edits produce minimal diffs.
- **Byte-precise spans** - every value carries an exact `u64` byte range; 1-indexed line/col
  are derived on demand via `Span.lineCol`. No input-size cap.
- **Reader-backed streaming** - `EventReader` and `ValueStream` for line-by-line or
  section-by-section bounded-memory processing from any `std.Io.Reader`.
- **Multi-error diagnostics** - one pass collects every parse error, with rustc-style
  rendering: source excerpt, caret underline, "did you mean" suggestions.
- **Authored conformance corpus** - multi-dialect fixture suite compared against `git` and
  Python `configparser` as reference oracles.
- **No dependencies** - pure Zig, libc-free.

```zig
const ini = @import("ini");

const Config = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
        tls: bool = false,
    },
};

const cfg = try ini.parseInto(Config, arena, src, .{});
```

## Install

Requires Zig 0.16.0 or newer.

```sh
zig fetch --save git+https://github.com/sakakibara/ini-zig
```

In `build.zig`:

```zig
const ini = b.dependency("ini", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ini", ini.module("ini"));
```

## Quickstart

### Parse

```zig
const std = @import("std");
const ini = @import("ini");

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const v = try ini.parse(arena,
    \\[server]
    \\host = 127.0.0.1
    \\port = 8080
, .{});

const host = v.section.get("server.host").?.string;

// getT decodes directly to a Zig type; null on missing path or type mismatch.
const port = try ini.getT(u16, arena, v, "server.port", .{});
```

`getT` walks dotted paths (e.g. `server.host`) and returns `null` on a missing path or
type mismatch; only allocation failure is an error. Optionals become `null` when absent.

### Dialects

```zig
// Default dialect is .generic (Python configparser-style).
// Switch with a single option:
const v = try ini.parse(arena, src, .{ .dialect = .gitconfig });

// Build a custom dialect from a preset:
const my_dialect: ini.Dialect = d: {
    var d = ini.Dialect.strict;
    d.global_keys = true;
    break :d d;
};
const v2 = try ini.parse(arena, src, .{ .dialect = my_dialect });
```

### Typed decoding

Decode straight into a struct. Field defaults are honored; unknown INI keys raise
`error.UnknownField` (opt out with `.ignore_unknown_fields = true`).

```zig
const LogLevel = enum { debug, info, warn, err };

const Config = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
        tls: bool = false,
    },
    log_level: LogLevel = .info,
    app_name: []const u8 = "app",
};

const cfg = try ini.parseInto(Config, arena, src, .{ .ignore_unknown_fields = true });
```

Supported types: `bool`, all int/float widths (overflow-checked), `[]const u8`, slices,
fixed-size arrays, optionals, nested structs, enums (by tag name). Embed a raw `ini.Value`
to keep a dynamic subtree.

For symmetric encoding of typed values, use `ini.encodeTyped(w, value, arena, options)`;
the struct type is inferred from `value`. Bind anonymous literals to a typed const first
so `ini_rename` / `ini_skip` / `ini_flatten` declarations are seen.
The plain `ini.encode(w, value, options)` applies for hand-built `Value` trees.

### Edit (lossless document model)

Read an INI file, edit values in place, emit byte-identical output when unmodified or
minimal-diff output when modified. Comments, whitespace, and key ordering are all preserved.

```zig
var doc = try ini.Document.parse(arena, src, .{});

const port = (try doc.getT(u16, "server.port")) orelse 0;

// set is comptime-dispatched on the Zig type:
try doc.set("server.port", @as(u16, 9443));
try doc.set("server.tls", true);

// Escape hatch: splice in a literal INI value string.
try doc.setLiteral("cache.ttl", "600");

try doc.remove("dev.unused");

// Comment editing:
try doc.addCommentBefore("cache.ttl", "seconds until entries expire");
try doc.setTrailingComment("server.host", "bind address");

var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
try doc.emit(&aw.writer);
```

`set` on an existing path replaces only the value's bytes; keys, comments, and surrounding
formatting stay put.

### Source spans

```zig
var spans: ini.Spans = .empty;
_ = try ini.parse(arena, src, .{ .spans = &spans });

if (spans.get("server.port")) |span| {
    // Spans store only u64 byte offsets; line/col are derived on demand.
    const lc = span.lineCol(src);
    std.debug.print("port at line {d} col {d}  bytes [{d}..{d}]\n", .{
        lc.line, lc.col, span.start, span.end,
    });
}
```

### Streaming

For processing a large or streamed INI file without buffering the full document, use
`EventReader`. It emits one `Event` at a time (section header, key/value, or comment); only
the current logical line is held in memory.

```zig
var r: std.Io.Reader = .fixed(src);
var er = ini.EventReader.fromReader(gpa, &r, .{});
defer er.deinit();

while (try er.next()) |ev| {
    switch (ev) {
        .section_header => |h| std.debug.print("[{s}]\n", .{h.name}),
        .key_value      => |kv| std.debug.print("  {s} = {s}\n", .{ kv.key, kv.value }),
        .comment        => |c| std.debug.print("  ; {s}\n", .{c.text}),
        .end_of_input   => {},
    }
}
```

**`ValueStream`** assembles one complete section `Value` per `next()` call. Reset a
per-section arena between calls to bound total memory:

```zig
var r: std.Io.Reader = .fixed(src);
var vs = ini.ValueStream.fromReader(gpa, &r, .{});
defer vs.deinit();

var item_arena: std.heap.ArenaAllocator = .init(gpa);
defer item_arena.deinit();
while (try vs.next(item_arena.allocator())) |section| {
    _ = section;
    _ = item_arena.reset(.retain_capacity);
}
```

**Borrow contract**: `Event` payload slices (`name`, `key`, `value`) are valid only until
the next call to `next()`. Copy with `arena.dupe(u8, s)` if you need to keep a value
across calls.

**`materialize`**: call `er.materialize(arena)` to compose the entire remaining stream into
an arena-allocated `Value` via the buffered parser (result cannot diverge from `parse`).
Intended to be called before draining any events; calling it mid-stream after a
`section_header` has been consumed drops that section from the output and can produce
`error.KeyBeforeSection` if bare keys follow. For per-section bounded-memory processing
use `ValueStream` instead.

### Diagnostics

`Diagnostic.render` (one line) and `Diagnostic.renderRich` (multi-line) both
take the source bytes, since a span stores only byte offsets and derives
line/col on demand.

```zig
var errs: std.ArrayList(ini.Diagnostic) = .empty;
defer errs.deinit(arena);
_ = ini.parse(arena, src, .{ .errors = &errs }) catch {
    if (errs.items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        defer aw.deinit();
        errs.items[0].render(&aw.writer, src) catch {};
        std.debug.print("{s}\n", .{aw.written()});
    }
    return;
};
```

For rustc-style multi-line output with source-line excerpts, caret underlines, and
"did you mean" suggestions:

```zig
for (errs.items) |d| try d.renderRich(stderr_writer, src);
```

Diagnostics are a buffered-parse feature: the streaming value paths (`ValueStream`, `materialize`) do not populate `errors` or `spans` (their entries would be backed by the per-item arena you reset between units). The parser collects every error in one pass when `errors` is set, resuming at the next
well-formed line. Set it to `null` for single-error mode (bail on the first error).

## Dialects

The five built-in presets cover the most common real-world INI families. Pass
`.{ .dialect = .gitconfig }` to select one, or build a custom `Dialect` by
starting from a preset and overriding individual fields.

| Preset | Separators | Subsections | Duplicate keys | Continuation | Quoting | Bare keys |
| --- | --- | --- | --- | --- | --- | --- |
| `generic` | `= :` | no | last wins | indent | none | no |
| `gitconfig` | `=` | `[sec "sub"]` | accumulate | backslash | git (`"..."`) | yes |
| `systemd` | `=` | no | accumulate | backslash | none | no |
| `windows` | `=` | no | last wins | none | none | no |
| `strict` | `=` | no | last wins | none | none | no |

All axes configurable on the `Dialect` struct:

| Field | Description |
| --- | --- |
| `comment_chars` | Characters that begin a line comment (e.g. `";"` or `";#"`). |
| `inline_comments` | Strip trailing inline comment from values. |
| `assign_chars` | Key/value separator characters (e.g. `"="` or `"=:"`). |
| `subsections` | Subsection syntax: `.none` or `.quoted` (git `[sec "sub"]` style). |
| `duplicate_keys` | Policy for repeated keys: `.last_wins`, `.first_wins`, `.accumulate`, `.err`. |
| `duplicate_sections` | Policy for repeated section headers: `.merge`, `.accumulate`, `.err`. |
| `global_keys` | Allow keys before any section header. |
| `case_insensitive_sections` | Match section names case-insensitively. |
| `case_insensitive_keys` | Match key names case-insensitively. |
| `line_continuation` | Continuation style: `.none`, `.backslash`, `.indent`. |
| `quoting` | Value quoting and escape rules: `.none` or `.git`. |
| `allow_no_value` | Accept a bare key (no `=`) as a boolean-true entry. |
| `trim_whitespace` | Trim leading/trailing whitespace around keys and values. |
| `trim_section_names` | Trim whitespace inside `[...]`; distinct from `trim_whitespace`. |
| `strip_value_quotes` | Strip one surrounding double-quote pair from values (Windows parity). |
| `int_suffixes` | Accept k/m/g multipliers in typed integer coercion. |

**gitconfig key charset**: key names must start with a letter (`[A-Za-z]`) and consist only
of `[A-Za-z0-9-]`; section names consist only of `[A-Za-z0-9.-]+`. Violations return
`error.InvalidKey` or `error.MalformedSectionHeader`.

**Windows quote stripping**: with `strip_value_quotes = true` (the `windows` preset), a
single surrounding pair of double quotes is removed from a value (`key="x"` -> `x`),
matching `GetPrivateProfileString` behavior. An unbalanced or single quote is kept verbatim.

## API surface

### Functions

| Function | Purpose |
| --- | --- |
| `parse(arena, src, options)` | Dynamic parse to a `Value` tree. |
| `parseReader(arena, reader, options)` | Reader-input variant. |
| `parseInto(T, arena, src, options)` | Decode straight into an instance of `T`. |
| `parseIntoReader(T, arena, reader, options)` | Reader-input typed decode into an instance of `T`. |
| `decode(T, arena, value, options)` | Decode an existing `Value` into `T`. |
| `encode(w, value, options)` | Emit INI to a `*std.Io.Writer`. |
| `encodeTyped(w, value, arena, options)` | Encode a typed value via comptime reflection. |
| `getT(T, arena, value, path, options)` | Decode a dotted-path entry to `T`; null on miss or mismatch, error on OOM. |
| `Document.parse(arena, src, options)` | Lossless parse for the document model. |
| `EventReader.fromReader(gpa, reader, options)` | Line-oriented event reader backed by a `std.Io.Reader`. |
| `EventReader.next()` | Pull the next `Event` (`null` at end of input). |
| `EventReader.materialize(arena)` | Compose the entire remaining stream into a `Value` via the buffered parser. |
| `ValueStream.fromReader(gpa, reader, options)` | Section iterator over a streamed INI document. |
| `ValueStream.next(item_arena)` | Pull the next section as a `Value`. |

### Types

`Value`, `Section`, `Span`, `Spans`, `Dialect`, `ParseOptions`, `Error`, `ReaderError`,
`Diagnostic`, `EmitOptions`, `EncodeError`, `TypedEncodeError`, `DecodeError`, `Document`,
`DocumentError`, `EventReader`, `Event`, `StreamError`, `ValueStream`, `Tokenizer`, `Token`, `LineKind`.

### Annotation-driven decode and encode

Structs opt into wire-format control with comptime declarations, mirroring
the sibling libraries:

```zig
const Config = struct {
    listen_addr: []const u8,
    log_level: []const u8 = "info",
    internal: u32 = 0,
    limits: Limits,

    pub const ini_rename = .{ .listen_addr = "listen-addr", .log_level = "log-level" };
    pub const ini_skip = .{"internal"};
    pub const ini_flatten = .{"limits"};
};
```

- `ini_rename` maps a field to a different key spelling (gitconfig keys
  cannot contain `_`, so `listen_addr` decodes from `listen-addr`).
- `ini_skip` excludes a field from both decode and encode; it takes its
  default value.
- `ini_flatten` spreads an inner struct's fields into the parent section
  instead of expecting a nested section.

Custom hooks: a struct with `pub fn fromIni(arena, value, options)` decodes
itself from the raw `Value`; `pub fn toIni(value, arena)` mirrors it on
encode.

### Errors

`parse` and streaming return `Error`; `encode` returns `EncodeError`; document editing
returns `DocumentError`. Errors a caller may want to match:

| Error | When |
| --- | --- |
| `LineTooLong` | Logical line exceeded `ParseOptions.max_line_len`. |
| `InvalidEscape` | Unknown backslash escape in a gitconfig value. |
| `InvalidKey` | Key name violated the gitconfig charset. |
| `UnterminatedQuote` | Gitconfig value left a double-quoted span open at line end. |
| `NestingTooDeep` | Subsection depth exceeded `ParseOptions.max_depth`. |
| `DuplicateKey` | Duplicate key under `duplicate_keys = .err`. |
| `DuplicateSection` | Repeated section under `duplicate_sections = .err`. |
| `MalformedSectionHeader` | Section header syntax invalid. |
| `KeyBeforeSection` | Key appeared before any header in a no-global-keys dialect. |
| `ExpectedAssignment` | Key/value line had no assignment character. |
| `EmptyKey` | Key was empty before or in place of the assignment character. |
| `CommentsNotSupported` | `setTrailingComment` called under a dialect without inline comments. |
| `ConflictingEdit` | Two document edits covered overlapping byte ranges. |
| `InvalidComment` | Comment text contained a newline character. |
| `UnrepresentableValue` | Value cannot be encoded or spliced without breaking document structure. |

Generated reference docs are published at **https://sakakibara.github.io/ini-zig/**.

Building locally (Zig's docs viewer is WASM-based and must be served over HTTP, not opened
as a `file://` URL):

```sh
zig build docs
cd zig-out/docs && python3 -m http.server 8000
# then visit http://localhost:8000/
```

## Build commands

```sh
zig build test           # unit + conformance + bounded fuzz regression tests
zig build fuzz           # random-input fuzzer (zig build fuzz -- --iters N)
zig build bench          # microbenchmarks (ReleaseFast)
zig build docs           # generate reference docs into zig-out/docs/
zig build examples       # build all examples
zig build example-basic  # run a specific example
```

## Conformance

Validated against an authored multi-dialect corpus in `tests/corpus/`:

- `generic/` -- Python `configparser`-style fixtures; differential harness compares against
  `configparser` as oracle.
- `gitconfig/` -- git-config-format fixtures; differential harness compares against
  `git config --list` as oracle.
- `systemd/` -- systemd unit-file fixtures (parser + encode round-trip).
- `windows/` -- Windows INI fixtures (parser + encode round-trip).

Run `zig build test` to execute the conformance suite. Run `tools/run_differential.sh`
(requires `git` and `python3`) to compare ini-zig output against the two reference oracles
for the `generic` and `gitconfig` corpora.

## Performance

Run the bench yourself on your hardware with your inputs:

```sh
zig build bench
```

The harness reports min/p50/p99/max latency and throughput across multiple samples with
explicit warmup. See `bench/main.zig`.

On aarch64-linux, ReleaseFast:

| Benchmark | Size | p50 latency | Throughput |
| --- | --- | --- | --- |
| parse | small (~495 B) | 1706 ns | 277 MB/s |
| parse | medium (~40 KB) | 401 us | 96 MB/s |
| parse | large (~230 KB) | 13.5 ms | 16 MB/s |
| encode | small (~495 B) | 311 ns | 1518 MB/s |
| encode | medium (~40 KB) | 18 us | 2123 MB/s |
| EventReader | 10,000 sections (~427 KB) | 22.3 ms | 19 MB/s |

(p50 latency; encode throughput is measured against the bytes produced.)

## Memory model

`parse` and friends accept an `Allocator` (the parse arena). All values, section names,
keys, and any non-zero-copy strings live in that arena. To free everything, deinit the
arena -- no need to walk the tree.

Strings parsed from the input may be zero-copy slices into the source buffer when no
escape processing is needed; otherwise they are arena-allocated copies. Either way, keep
the input alive for as long as the parse tree is in use.

The document model also takes an arena. It owns the source string, the node tree, and any
edits. Each edit retains a new source/tree generation in the arena, so memory grows with
edit count; for long-lived many-edit sessions, periodically emit and re-parse into a fresh
arena.

## Limits

- **Nesting cap** - `ParseOptions.max_depth` (default 128) limits subsection depth.
  Exceeding it returns `error.NestingTooDeep`.
- **Line length cap** - `ParseOptions.max_line_len` (default 16 MiB) bounds the raw byte
  length of one logical line: the primary physical line plus any continuation and absorbed-
  blank lines joined into it, including newlines, comments, quotes, and escape bytes. Applies
  in both buffered parse and `EventReader`/`ValueStream`; exceeding it returns
  `error.LineTooLong`.
- **Unrepresentable values** - `encode` returns `error.UnrepresentableValue` when a value
  contains an embedded newline that the target dialect cannot express - dialects with neither
  indent continuation nor git-style `\n` escaping (`strict`, `windows`, `systemd`). The
  `generic` and `gitconfig` dialects encode embedded newlines losslessly.

## Examples

See `examples/` for runnable samples:

- `basic.zig` -- dynamic parse and dotted-path access
- `typed.zig` -- decode straight into a Zig struct
- `edit.zig` -- lossless document edit + emit
- `spans.zig` -- source spans and diagnostics
- `stream.zig` -- EventReader and ValueStream, per-section arena reset
- `dialects.zig` -- same input parsed under all five presets, divergence demonstrated
