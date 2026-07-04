//! INI encoder: emit a Value tree back to INI text.
//!
//! `encode` walks the root Section, emits global/root leaves first, then
//! each named section with a `[name]` header. For git-style dialects with
//! subsection syntax, a section whose children are themselves sections is
//! emitted as one `[parent "child"]` header per child rather than a flat
//! `[parent]` block. Multi-value lists emit one repeated key line per
//! element. Values are escaped per the dialect's quoting rules.

const std = @import("std");
const Value = @import("value.zig").Value;
const Section = @import("value.zig").Section;
const Entry = @import("value.zig").Entry;
const Dialect = @import("dialect.zig").Dialect;
const SubsectionStyle = @import("dialect.zig").SubsectionStyle;
const QuoteStyle = @import("dialect.zig").QuoteStyle;
const escape = @import("escape.zig");
const escapeGit = escape.escapeGit;
const ann = @import("annotations.zig");
const parser = @import("parser.zig");

pub const EncodeError = error{
    /// `encode` was called on a `Value` that is not `.section`.
    ExpectedSection,
    /// A value (or subsection name, or multi-value list) cannot be encoded so
    /// that a re-parse reproduces it under the active dialect, e.g. a carriage
    /// return (no dialect can carry it), leading/trailing whitespace or an
    /// embedded newline under a non-quoting dialect, a value ending in an
    /// odd-parity backslash run under backslash continuation, or a multi-value
    /// list under a dialect that does not accumulate duplicate keys. The
    /// encoder rejects rather than silently emit corruptible output.
    UnrepresentableValue,
} || std.Io.Writer.Error;

pub const TypedEncodeError = std.mem.Allocator.Error || EncodeError;

pub const EmitOptions = struct {
    dialect: Dialect = .generic,
    indent: []const u8 = "",
    assign: []const u8 = " = ",
    blank_line_between_sections: bool = true,
    /// `false` (default) preserves insertion/declaration order, so existing
    /// output is byte-for-byte unchanged unless set. `true` emits each
    /// section's key/value pairs, and the sections themselves, in ascending
    /// byte-lexicographic order, recursively -- ordering only, not
    /// canonicalization: values are still quoted/escaped exactly as before.
    sort_keys: bool = false,
};

/// Ascending order over `(key, original index)`: keys compare
/// byte-lexicographically; a tie (a duplicate key) breaks by original index
/// so equal keys keep their original relative order (a stable sort).
fn entryLess(entries: []const Entry, a: usize, b: usize) bool {
    const ak = entries[a].key;
    const bk = entries[b].key;
    if (!std.mem.eql(u8, ak, bk)) return std.mem.lessThan(u8, ak, bk);
    return a < b;
}

/// Index of the entry immediately following `after` in ascending
/// `(key, original index)` order, or null once every entry has been visited.
/// Selection-scan: O(n) per call, O(n^2) for a full pass. No allocation, so
/// `encode` (which takes no allocator) can sort without one; `sort_keys`
/// targets human-scale INI files where the quadratic cost is negligible.
fn nextSortedIndex(entries: []const Entry, after: ?usize) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |_, j| {
        if (after) |a| {
            if (!entryLess(entries, a, j)) continue;
        }
        if (best) |b| {
            if (entryLess(entries, j, b)) best = j;
        } else best = j;
    }
    return best;
}

/// Yields entry indices in original order, or ascending sorted order when
/// `sort_keys` is set, so callers walk one loop regardless of `EmitOptions`.
const EntryOrder = struct {
    entries: []const Entry,
    sort_keys: bool,
    seq: usize = 0,
    prev: ?usize = null,

    fn next(self: *EntryOrder) ?usize {
        if (!self.sort_keys) {
            if (self.seq >= self.entries.len) return null;
            const idx = self.seq;
            self.seq += 1;
            return idx;
        }
        const idx = nextSortedIndex(self.entries, self.prev) orelse return null;
        self.prev = idx;
        return idx;
    }
};

/// Encode one optional struct field, recursing through any number of stacked
/// optional layers. Null at any depth -> field omitted (same as single `?T`
/// null). Mirrors `decodeOptional`'s unbounded recursion so every `??T` /
/// `???T` field that decodes also encodes.
fn appendOptionalField(
    comptime T: type,
    value: T,
    key: []const u8,
    arena: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
) TypedEncodeError!void {
    const Child = @typeInfo(T).optional.child;
    const inner = value orelse return; // null at any depth -> omit
    if (comptime @typeInfo(Child) == .optional) {
        return appendOptionalField(Child, inner, key, arena, entries);
    }
    const ev = try scalarToValue(Child, inner, arena);
    try entries.append(arena, .{ .key = key, .value = ev });
}

fn appendStructEntries(
    comptime T: type,
    value: T,
    arena: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
) TypedEncodeError!void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime ann.isSkipped(T, field.name)) continue;
        const fv = @field(value, field.name);
        const eff_key = comptime ann.renamedKey(T, field.name);
        if (comptime ann.isFlattened(T, field.name)) {
            try appendStructEntries(field.type, fv, arena, entries);
            continue;
        }
        if (comptime @typeInfo(field.type) == .optional) {
            try appendOptionalField(field.type, fv, eff_key, arena, entries);
        } else {
            const ev = try scalarToValue(field.type, fv, arena);
            try entries.append(arena, .{ .key = eff_key, .value = ev });
        }
    }
}

/// Canonical INI text for a bool. Scalar fields and slice elements share this
/// so a `bool` and a `[]const bool` element encode to identical bytes.
fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn scalarToValue(comptime T: type, value: T, arena: std.mem.Allocator) TypedEncodeError!Value {
    return switch (@typeInfo(T)) {
        .bool => .{ .string = boolText(value) },
        .int => .{ .string = try std.fmt.allocPrint(arena, "{d}", .{value}) },
        .float => .{ .string = try std.fmt.allocPrint(arena, "{}", .{value}) },
        .@"enum" => .{ .string = @tagName(value) },
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("encodeTyped: only slice pointers supported");
            if (p.child == u8 and p.is_const) break :blk Value{ .string = value };
            if (value.len == 0) break :blk Value{ .list = &.{} };
            if (value.len == 1) {
                const s = try scalarToStr(p.child, value[0], arena);
                break :blk Value{ .string = s };
            }
            const strings = try arena.alloc([]const u8, value.len);
            for (value, 0..) |item, i| strings[i] = try scalarToStr(p.child, item, arena);
            break :blk Value{ .list = strings };
        },
        .@"struct" => try structToSection(T, value, arena),
        else => @compileError("encodeTyped: unsupported type " ++ @typeName(T)),
    };
}

/// Render one multi-value slice element to its INI text. Recurses structurally
/// over the same type surface `decodeInner` accepts so every element type the
/// decoder compiles for also compiles here. Element shapes the flat INI model
/// cannot carry (a null optional slot, a nested list, a struct that does not
/// serialize to a scalar) return `error.UnrepresentableValue` at runtime rather
/// than a compile error.
fn scalarToStr(comptime T: type, value: T, arena: std.mem.Allocator) TypedEncodeError![]const u8 {
    switch (@typeInfo(T)) {
        .bool => return boolText(value),
        .int => return std.fmt.allocPrint(arena, "{d}", .{value}),
        .float => return std.fmt.allocPrint(arena, "{}", .{value}),
        .@"enum" => return @tagName(value),
        .optional => |o| {
            // decode never yields a null multi-value element -- an empty raw
            // value coerces to a scalar, never to null -- so a null element has
            // no representation that would round-trip.
            const inner = value orelse return error.UnrepresentableValue;
            return scalarToStr(o.child, inner, arena);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("encodeTyped: unsupported slice element type " ++ @typeName(T));
            // A string element is one scalar; any other slice is a nested list,
            // and a multi-value line carries scalars, not lists.
            if (p.child == u8 and p.is_const) return value;
            return error.UnrepresentableValue;
        },
        .@"struct" => {
            // A struct element round-trips only when its `toIni` collapses it to
            // a single scalar (decode reads elements from a scalar string); a
            // section cannot be one multi-value element.
            const sv = try structToSection(T, value, arena);
            return switch (sv) {
                .string => |s| s,
                else => error.UnrepresentableValue,
            };
        },
        else => @compileError("encodeTyped: unsupported slice element type " ++ @typeName(T)),
    }
}

fn structToSection(comptime T: type, value: T, arena: std.mem.Allocator) TypedEncodeError!Value {
    if (comptime @hasDecl(T, "toIni")) return T.toIni(value, arena);
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    try appendStructEntries(T, value, arena, &entries);
    const sec = try arena.create(Section);
    sec.* = .{ .entries = try entries.toOwnedSlice(arena) };
    return .{ .section = sec };
}

/// Encode a typed Zig struct as INI text without building an intermediate Value tree.
///
/// Reflects T into a `Value` (honoring `ini_rename`, `ini_skip`, `ini_flatten`,
/// and optional `toIni` hooks), then delegates to `encode`.
pub fn encodeTyped(
    w: *std.Io.Writer,
    value: anytype,
    arena: std.mem.Allocator,
    options: EmitOptions,
) TypedEncodeError!void {
    const T = @TypeOf(value);
    if (@typeInfo(T) != .@"struct") @compileError("encodeTyped: root must be a struct, got " ++ @typeName(T));
    const v = try structToSection(T, value, arena);
    return encode(w, v, options);
}

/// Encode `value` as INI text to `w` using `options`.
///
/// `value` must be `.section`; any other variant returns `error.ExpectedSection`.
pub fn encode(w: *std.Io.Writer, value: Value, options: EmitOptions) EncodeError!void {
    if (value != .section) return error.ExpectedSection;
    var first = true;
    try encodeRoot(w, value.section, options, &first);
}

fn encodeRoot(
    w: *std.Io.Writer,
    root: *Section,
    options: EmitOptions,
    first: *bool,
) EncodeError!void {
    // Reject global leaf keys under a dialect that forbids keys before any section.
    // An empty list emits nothing, so it is allowed even under global_keys=false.
    if (!options.dialect.global_keys) {
        for (root.entries) |entry| {
            switch (entry.value) {
                .string => return error.UnrepresentableValue,
                .list => |items| if (items.len > 0) return error.UnrepresentableValue,
                .section => {},
            }
        }
    }

    // Phase 1: global leaf entries (string/list directly under root).
    var leaves = EntryOrder{ .entries = root.entries, .sort_keys = options.sort_keys };
    while (leaves.next()) |i| {
        const entry = root.entries[i];
        switch (entry.value) {
            .string => |s| {
                try emitKv(w, entry.key, s, options);
                first.* = false;
            },
            .list => |items| {
                try emitList(w, entry.key, items, options);
                if (items.len > 0) first.* = false;
            },
            .section => {},
        }
    }

    // Phase 2: section entries, each becoming one or more header blocks.
    var sections = EntryOrder{ .entries = root.entries, .sort_keys = options.sort_keys };
    while (sections.next()) |i| {
        const entry = root.entries[i];
        if (entry.value != .section) continue;
        try encodeSection(w, entry.key, entry.value.section, options, first);
    }
}

fn encodeSection(
    w: *std.Io.Writer,
    name: []const u8,
    sec: *Section,
    options: EmitOptions,
    first: *bool,
) EncodeError!void {
    if (identifierUnrepresentable(name)) return error.UnrepresentableValue;
    // A git-quoting dialect accepts only the git section-name charset (alnum,
    // '.', '-'); a name with '_' or space fails to re-parse
    // (MalformedSectionHeader). Subsection names (the quoted child) carry a
    // more permissive rule and are handled by writeSubsectionLiteral.
    if (options.dialect.quoting == .git and !parser.validGitSectionName(name)) {
        return error.UnrepresentableValue;
    }
    var has_leaves = false;
    var has_subsecs = false;
    for (sec.entries) |e| {
        switch (e.value) {
            .string, .list => has_leaves = true,
            .section => has_subsecs = true,
        }
    }

    if (has_subsecs and options.dialect.subsections == .quoted) {
        // Git-style: each child section becomes [name "child"].

        // Emit direct leaves under a plain [name] header first, if any exist.
        if (has_leaves) {
            try emitBlankBefore(w, options, first);
            try w.writeByte('[');
            try w.writeAll(name);
            try w.writeAll("]\n");
            var it = EntryOrder{ .entries = sec.entries, .sort_keys = options.sort_keys };
            while (it.next()) |i| {
                const e = sec.entries[i];
                switch (e.value) {
                    .string => |s| try emitKv(w, e.key, s, options),
                    .list => |items| try emitList(w, e.key, items, options),
                    .section => {},
                }
            }
        }

        // Emit each child section as [name "child"].
        var subs = EntryOrder{ .entries = sec.entries, .sort_keys = options.sort_keys };
        while (subs.next()) |i| {
            const e = sec.entries[i];
            if (e.value != .section) continue;
            try emitBlankBefore(w, options, first);
            try w.writeByte('[');
            try w.writeAll(name);
            try w.writeAll(" \"");
            try writeSubsectionLiteral(w, e.key);
            try w.writeAll("\"]\n");
            var leaves = EntryOrder{ .entries = e.value.section.entries, .sort_keys = options.sort_keys };
            while (leaves.next()) |li| {
                const leaf = e.value.section.entries[li];
                switch (leaf.value) {
                    .string => |s| try emitKv(w, leaf.key, s, options),
                    .list => |items| try emitList(w, leaf.key, items, options),
                    // Git subsections nest exactly one level ([name "child"]); a
                    // deeper section cannot be expressed. Reject rather than drop.
                    .section => return error.UnrepresentableValue,
                }
            }
        }
    } else {
        try emitBlankBefore(w, options, first);
        try w.writeByte('[');
        try w.writeAll(name);
        try w.writeAll("]\n");
        var it = EntryOrder{ .entries = sec.entries, .sort_keys = options.sort_keys };
        while (it.next()) |i| {
            const e = sec.entries[i];
            switch (e.value) {
                .string => |s| try emitKv(w, e.key, s, options),
                .list => |items| try emitList(w, e.key, items, options),
                // A dialect without subsection syntax cannot carry a nested
                // section; emitting only [name] would silently lose its data.
                .section => return error.UnrepresentableValue,
            }
        }
    }
}

fn emitBlankBefore(
    w: *std.Io.Writer,
    options: EmitOptions,
    first: *bool,
) EncodeError!void {
    if (!first.* and options.blank_line_between_sections) try w.writeByte('\n');
    first.* = false;
}

/// True when a key or section name contains chars that break re-parse: a newline
/// or carriage return splits the header or key line; `]` terminates a section
/// header early before its closing delimiter.
fn identifierUnrepresentable(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\n\r]") != null;
}

/// True when `key` would not re-parse (same dialect) to the identical key.
/// Beyond the structural breaks in `identifierUnrepresentable`, the parser
/// would split, re-tag, drop, or mutate a key that: is empty (no key before the
/// separator); contains an assignment char (splits key from value); begins with
/// a comment char (the whole line is read as a comment, dropping the key);
/// begins with `[` (the line re-parses as a section header); or, under
/// `trim_whitespace`, carries leading/trailing space or tab (trimmed away on
/// re-parse). Rejecting here upholds the encoder's no-silent-corruption
/// contract. A non-leading comment char is left alone: the parser only starts a
/// comment at a line's first non-blank byte, so an interior `#`/`;` survives.
fn keyUnrepresentable(dialect: Dialect, key: []const u8) bool {
    // A git-quoting dialect accepts only the git key charset
    // ([A-Za-z][A-Za-z0-9-]*); every other key fails to re-parse
    // (error.InvalidKey). Gate on the parser's own predicate, keyed on the
    // quoting style rather than any specific preset.
    if (dialect.quoting == .git) return !parser.validGitKey(key);
    if (identifierUnrepresentable(key)) return true;
    if (key.len == 0) return true;
    if (std.mem.indexOfAny(u8, key, dialect.assign_chars) != null) return true;
    if (std.mem.indexOfScalar(u8, dialect.comment_chars, key[0]) != null) return true;
    if (key[0] == '[') return true;
    if (dialect.trim_whitespace) {
        const f = key[0];
        const l = key[key.len - 1];
        if (f == ' ' or f == '\t' or l == ' ' or l == '\t') return true;
    }
    return false;
}

/// Emit `key`/`val` as one logical entry, rejecting any value that would not
/// round-trip under the dialect. A carriage return is unrepresentable in every
/// dialect (a tokenizer line terminator with no git escape). An embedded
/// newline routes to indent continuation, is git-escaped, or is rejected. All
/// remaining single-line cases (trimmed whitespace, continuation-swallowing
/// trailing backslash) are gated by the shared representability check.
fn emitKv(
    w: *std.Io.Writer,
    key: []const u8,
    val: []const u8,
    options: EmitOptions,
) EncodeError!void {
    if (keyUnrepresentable(options.dialect, key)) return error.UnrepresentableValue;
    if (std.mem.indexOfScalar(u8, val, '\r') != null) return error.UnrepresentableValue;

    const has_newline = std.mem.indexOfScalar(u8, val, '\n') != null;
    if (has_newline) {
        if (options.dialect.line_continuation == .indent) {
            return emitIndentContinuation(w, key, val, options);
        }
        // git quoting escapes a `\n` to a literal `\n` on a single line; any
        // other dialect has no way to carry an embedded newline through a
        // re-parse.
        if (options.dialect.quoting != .git) return error.UnrepresentableValue;
    }
    if (escape.unrepresentableSingleLine(options.dialect, val)) return error.UnrepresentableValue;

    try w.writeAll(options.indent);
    try w.writeAll(key);
    try w.writeAll(options.assign);
    try writeValue(w, val, options);
    try w.writeByte('\n');
}

/// Emit a multi-value list as one key line per element, rejecting a >1-element
/// list under a dialect that does not accumulate duplicate keys: a re-parse
/// would keep only the first or last element (last_wins/first_wins) or fail
/// (err), silently dropping values. A 0- or 1-element list is safe everywhere.
fn emitList(
    w: *std.Io.Writer,
    key: []const u8,
    items: []const []const u8,
    options: EmitOptions,
) EncodeError!void {
    if (items.len > 1 and options.dialect.duplicate_keys != .accumulate) {
        return error.UnrepresentableValue;
    }
    for (items) |item| try emitKv(w, key, item, options);
}

/// Emit a newline-bearing value as an indent-continuation block: the first
/// segment on the `key<assign>...` line, each later segment on its own line
/// indented one whitespace level deeper than the key so the tokenizer rejoins
/// them with `\n`. Any segment that differs from its whitespace-trimmed form
/// cannot round-trip: the parser trims continuation lines with
/// std.mem.trim(u8, s, " \t\r"), and a whitespace-only interior line is
/// classified as blank, terminating the block. Returns `error.UnrepresentableValue`
/// for any such segment.
fn emitIndentContinuation(
    w: *std.Io.Writer,
    key: []const u8,
    val: []const u8,
    options: EmitOptions,
) EncodeError!void {
    var it = std.mem.splitScalar(u8, val, '\n');
    const first = it.first();
    if (!std.mem.eql(u8, first, std.mem.trim(u8, first, " \t\r"))) return error.UnrepresentableValue;
    try w.writeAll(options.indent);
    try w.writeAll(key);
    try w.writeAll(options.assign);
    try writeValue(w, first, options);
    try w.writeByte('\n');
    while (it.next()) |seg| {
        if (seg.len == 0 or !std.mem.eql(u8, seg, std.mem.trim(u8, seg, " \t\r"))) return error.UnrepresentableValue;
        try w.writeAll(options.indent);
        try w.writeByte('\t');
        try writeValue(w, seg, options);
        try w.writeByte('\n');
    }
}

fn writeValue(w: *std.Io.Writer, s: []const u8, options: EmitOptions) EncodeError!void {
    if (options.dialect.quoting == .git) {
        try escapeGit(w, s);
    } else {
        try w.writeAll(s);
    }
}

/// Emit a subsection name inside the surrounding double quotes of a git config
/// header. The parser stores subsection names unescaped (e.g. `my\repo`), so
/// the encoder re-escapes `\` and `"` so a re-parse round-trips cleanly. A name
/// bearing a newline or carriage return cannot live inside a single `[name
/// "..."]` header line: it would split the header and re-parse as
/// `MalformedSectionHeader`, so it is rejected rather than emitted.
fn writeSubsectionLiteral(w: *std.Io.Writer, s: []const u8) EncodeError!void {
    if (std.mem.indexOfAny(u8, s, "\n\r") != null) return error.UnrepresentableValue;
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(c),
        }
    }
}


const testing = std.testing;
const parse = @import("parser.zig").parse;

test "encode then parse is stable for gitconfig multi-values" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = G });
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G, .indent = "\t", .assign = " = " });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try std.testing.expectEqualStrings("u", v2.get("remote.o.url").?.string);
    try std.testing.expectEqual(@as(usize, 2), v2.get("remote.o.push").?.list.len);
}

test "encode plain section round-trips" {
    const src = "[user]\nname = Ada\nemail = a@example.com\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = Dialect.strict });
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = Dialect.strict });
    const v2 = try parse(a, aw.written(), .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("Ada", v2.get("user.name").?.string);
    try testing.expectEqualStrings("a@example.com", v2.get("user.email").?.string);
}

test "encode non-section value returns ExpectedSection" {
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.ExpectedSection, encode(&w, .{ .string = "x" }, .{}));
}

test "encode blank_line_between_sections inserts blank line" {
    const src = "[a]\nk = 1\n[b]\nk = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = Dialect.strict });
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = Dialect.strict, .blank_line_between_sections = true });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\n\n") != null);
}

test "encode blank_line_between_sections false omits blank lines" {
    const src = "[a]\nk = 1\n[b]\nk = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = Dialect.strict });
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = Dialect.strict, .blank_line_between_sections = false });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\n\n") == null);
}

test "encode gitconfig: value with special chars escapes correctly" {
    const G = Dialect.gitconfig;
    const src = "[s]\nk = hello\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = G });
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings("hello", v2.get("s.k").?.string);
}

test "encode gitconfig subsection name with backslash round-trips" {
    // "[remote \"my\\\\repo\"]" in Zig = source text [remote "my\\repo"].
    // The parser unescapes \\ to \, so the stored subsection key is "my\repo"
    // (one backslash). The encoder re-escapes it to "my\\repo" so a re-parse
    // yields the same "my\repo" stored key. Round-trip: source -> stored -> source.
    const G = Dialect.gitconfig;
    const src = "[remote \"my\\\\repo\"]\n\turl = x\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = G });
    // After unescaping, the stored subsection key is "my\repo" (one backslash).
    try testing.expectEqualStrings("x", v1.get("remote.my\\repo.url").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G, .indent = "\t" });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings("x", v2.get("remote.my\\repo.url").?.string);
}

test "encodeTyped uses toIni hook when present" {
    // A type whose toIni method emits a fixed single-key section.
    const Tagged = struct {
        tag: []const u8,

        pub fn toIni(self: @This(), arena: std.mem.Allocator) std.mem.Allocator.Error!Value {
            const entries = try arena.alloc(Entry, 1);
            entries[0] = .{ .key = "tag", .value = .{ .string = self.tag } };
            const sec = try arena.create(Section);
            sec.* = .{ .entries = entries };
            return .{ .section = sec };
        }
    };
    const Root = struct { item: Tagged };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = Root{ .item = .{ .tag = "hello" } };
    var aw: std.Io.Writer.Allocating = .init(a);
    try encodeTyped(&aw.writer, root, a, .{ .dialect = Dialect.strict });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "tag = hello") != null);
}

test "encode generic indent continuation round-trips a multi-line value" {
    const G = Dialect.generic;
    const src = "[s]\nkey : line one\n    line two\n    line three\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = G });
    try testing.expectEqualStrings("line one\nline two\nline three", v1.get("s.key").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings("line one\nline two\nline three", v2.get("s.key").?.string);
}

test "encode generic indent continuation round-trips a leading-empty segment" {
    // `key =` with an empty value then an indented continuation yields a value
    // that begins with `\n`; the encoder must reproduce that exact shape.
    const G = Dialect.generic;
    const src = "[s]\nkey =\n    tail\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = G });
    try testing.expectEqualStrings("\ntail", v1.get("s.key").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings("\ntail", v2.get("s.key").?.string);
}

fn singleKeySection(a: std.mem.Allocator, key: []const u8, str: []const u8) !Value {
    const leaf = try a.alloc(Entry, 1);
    leaf[0] = .{ .key = key, .value = .{ .string = str } };
    const inner = try a.create(Section);
    inner.* = .{ .entries = leaf };
    const outer = try a.alloc(Entry, 1);
    outer[0] = .{ .key = "s", .value = .{ .section = inner } };
    const root = try a.create(Section);
    root.* = .{ .entries = outer };
    return .{ .section = root };
}

test "encode strict/windows: embedded newline is UnrepresentableValue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try singleKeySection(a, "k", "a\nb");
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = Dialect.strict }));
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = Dialect.windows }));
    // systemd's backslash continuation concatenates without a separator, so it
    // also cannot carry an embedded newline.
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = Dialect.systemd }));
}

test "encode gitconfig: embedded newline round-trips via the \\n escape" {
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try singleKeySection(a, "k", "a\nb");
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G, .indent = "\t" });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings("a\nb", v2.get("s.k").?.string);
}

test "encodeTyped round-trips a nested struct through parse" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const parseInto = @import("decode.zig").parseInto;
    const Sec = struct { url: []const u8 };
    const Config = struct { remote: Sec };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Config{ .remote = .{ .url = "git@example.com" } };
    var aw: std.Io.Writer.Allocating = .init(a);
    try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G });
    const cfg2 = try parseInto(Config, a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings(cfg.remote.url, cfg2.remote.url);
}

test "encode generic: whitespace-only interior segment is UnrepresentableValue" {
    const G = Dialect.generic;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try singleKeySection(a, "k", "a\n \nb");
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = G }));
}

test "encode generic: leading-whitespace interior segment is UnrepresentableValue" {
    const G = Dialect.generic;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try singleKeySection(a, "k", "a\n  b");
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = G }));
}

test "encode generic: trailing-whitespace interior segment is UnrepresentableValue" {
    const G = Dialect.generic;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try singleKeySection(a, "k", "a\nb ");
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = G }));
}

test "encode gitconfig: quoted hash survives parse->encode->parse round-trip" {
    // A value containing '#' must be quoted by the encoder so the '#' is not
    // treated as an inline comment on re-parse.
    const G = Dialect.gitconfig;
    const src = "[s]\n\tx = \"a # b\"\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = try parse(a, src, .{ .dialect = G });
    try testing.expectEqualStrings("a # b", v1.get("s.x").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v1, .{ .dialect = G, .indent = "\t" });
    const v2 = try parse(a, aw.written(), .{ .dialect = G });
    try testing.expectEqualStrings("a # b", v2.get("s.x").?.string);
}

test "encode generic: whitespace-bearing first segment is UnrepresentableValue" {
    const G = Dialect.generic;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try singleKeySection(a, "k", " a\nb");
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = G }));
}

fn singleListSection(a: std.mem.Allocator, key: []const u8, items: []const []const u8) !Value {
    const leaf = try a.alloc(Entry, 1);
    leaf[0] = .{ .key = key, .value = .{ .list = items } };
    const inner = try a.create(Section);
    inner.* = .{ .entries = leaf };
    const outer = try a.alloc(Entry, 1);
    outer[0] = .{ .key = "s", .value = .{ .section = inner } };
    const root = try a.create(Section);
    root.* = .{ .entries = outer };
    return .{ .section = root };
}

fn expectEncodeError(a: std.mem.Allocator, v: Value, d: Dialect) !void {
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{ .dialect = d }));
}

fn expectScalarRoundTrips(a: std.mem.Allocator, key: []const u8, val: []const u8, d: Dialect) !void {
    const v = try singleKeySection(a, key, val);
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v, .{ .dialect = d, .indent = "\t" });
    const v2 = try parse(a, aw.written(), .{ .dialect = d });
    const got = v2.get("s.k") orelse return error.Missing;
    try testing.expectEqualStrings(val, got.string);
}

const non_git_dialects = [_]Dialect{ Dialect.strict, Dialect.windows, Dialect.systemd, Dialect.generic };

/// A non-preset dialect that still uses git quoting: proves git-key/section
/// validation keys off `dialect.quoting == .git` (the parser's own signal),
/// not an identity comparison against the `gitconfig` preset.
const git_indent_dialect: Dialect = blk: {
    var d = Dialect.gitconfig;
    d.comment_chars = "#";
    break :blk d;
};

test "E1: leading/trailing whitespace is UnrepresentableValue under non-git dialects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ " lead", "trail ", "  both  ", "\tlead", "trail\t" }) |val| {
        for (non_git_dialects) |d| {
            const v = try singleKeySection(a, "k", val);
            try expectEncodeError(a, v, d);
        }
        // gitconfig represents edge whitespace via quoting and must round-trip.
        try expectScalarRoundTrips(a, "k", val, Dialect.gitconfig);
    }
}

test "E2: systemd value ending in an odd backslash run swallows the next key -> error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "a\" (one trailing backslash) under systemd's backslash continuation.
    const v = try singleKeySection(a, "k", "a\\");
    try expectEncodeError(a, v, Dialect.systemd);
    // An even-parity run is two literal backslashes, no continuation, fine.
    try expectScalarRoundTrips(a, "k", "a\\\\", Dialect.systemd);
    // gitconfig escapes backslashes, so it round-trips.
    try expectScalarRoundTrips(a, "k", "a\\", Dialect.gitconfig);
}

test "E3: carriage return is UnrepresentableValue in every dialect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ Dialect.strict, Dialect.windows, Dialect.systemd, Dialect.generic, Dialect.gitconfig }) |d| {
        const v = try singleKeySection(a, "k", "a\rb");
        try expectEncodeError(a, v, d);
    }
    // Interior CR inside an indent-continuation segment is also rejected, not
    // emitted into a line that re-parses broken.
    const v = try singleKeySection(a, "k", "a\nb\rc");
    try expectEncodeError(a, v, Dialect.generic);
}

test "E4: multi-value list under a non-accumulate dialect is UnrepresentableValue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = [_][]const u8{ "x", "y" };
    // last_wins / first_wins / err dialects would drop elements on re-parse.
    for ([_]Dialect{ Dialect.strict, Dialect.windows, Dialect.generic }) |d| {
        const v = try singleListSection(a, "k", &two);
        try expectEncodeError(a, v, d);
    }
    // Accumulating dialects keep every element; a 2-element list round-trips.
    for ([_]Dialect{ Dialect.systemd, Dialect.gitconfig }) |d| {
        const v = try singleListSection(a, "k", &two);
        var aw: std.Io.Writer.Allocating = .init(a);
        try encode(&aw.writer, v, .{ .dialect = d, .indent = "\t" });
        const v2 = try parse(a, aw.written(), .{ .dialect = d });
        try testing.expectEqual(@as(usize, 2), v2.get("s.k").?.list.len);
    }
    // A 1-element list is representable everywhere.
    const one = [_][]const u8{"only"};
    for (non_git_dialects) |d| {
        const v = try singleListSection(a, "k", &one);
        var aw: std.Io.Writer.Allocating = .init(a);
        try encode(&aw.writer, v, .{ .dialect = d });
        const v2 = try parse(a, aw.written(), .{ .dialect = d });
        try testing.expectEqualStrings("only", v2.get("s.k").?.string);
    }
}

test "E4: encodeTyped multi-value slice under last-wins dialect is UnrepresentableValue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Cfg = struct { s: struct { k: []const []const u8 } };
    const cfg = Cfg{ .s = .{ .k = &.{ "x", "y" } } };
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, cfg, a, .{ .dialect = Dialect.strict }));
}

test "E6: git subsection name with a newline is UnrepresentableValue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = try a.alloc(Entry, 1);
    url[0] = .{ .key = "url", .value = .{ .string = "u" } };
    const child = try a.create(Section);
    child.* = .{ .entries = url };
    const ce = try a.alloc(Entry, 1);
    ce[0] = .{ .key = "a\nb", .value = .{ .section = child } };
    const remote = try a.create(Section);
    remote.* = .{ .entries = ce };
    const oe = try a.alloc(Entry, 1);
    oe[0] = .{ .key = "remote", .value = .{ .section = remote } };
    const root = try a.create(Section);
    root.* = .{ .entries = oe };
    var aw: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, .{ .section = root }, .{ .dialect = Dialect.gitconfig, .indent = "\t" }));
    // A carriage return in a subsection name is rejected the same way.
    ce[0] = .{ .key = "a\rb", .value = .{ .section = child } };
    var aw2: std.Io.Writer.Allocating = .init(a);
    try testing.expectError(error.UnrepresentableValue, encode(&aw2.writer, .{ .section = root }, .{ .dialect = Dialect.gitconfig, .indent = "\t" }));
}

test "property: any value encode accepts under any dialect round-trips through parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_][]const u8{
        "",            "plain",        "with space",   "a # b",        "a ; b",
        " lead",       "trail ",       "  both  ",     "\tlead",       "a\tb",
        "a\nb",        "a\n\nb",        "\ntail",       "a\rb",         "a\r\nb",
        "a\\",         "a\\\\",         "a\\\\\\",      "a\\b",         "[x]",
        "a\"b",        "a\x07b",        "a\x00b",       "a\x1bb",       "=v",
        "k=v",         "a\nb\rc",       " a\nb ",       "value\x08end",
    };
    inline for (.{ Dialect.strict, Dialect.windows, Dialect.systemd, Dialect.generic, Dialect.gitconfig }) |d| {
        for (values) |val| {
            const v = try singleKeySection(a, "k", val);
            var aw: std.Io.Writer.Allocating = .init(a);
            encode(&aw.writer, v, .{ .dialect = d, .indent = "\t" }) catch |e| switch (e) {
                error.UnrepresentableValue => continue,
                else => return e,
            };
            const v2 = try parse(a, aw.written(), .{ .dialect = d });
            const got = v2.get("s.k") orelse {
                std.debug.print("property: value {x} vanished under dialect\n", .{val});
                return error.SilentCorruption;
            };
            if (got != .string or !std.mem.eql(u8, got.string, val)) {
                std.debug.print("property: value {x} corrupted to {any}\n", .{ val, got });
                return error.SilentCorruption;
            }
        }
    }
}

test "D3: encodeTyped optional field round-trips (null omitted, present carried)" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    const Inner = struct { name: []const u8, tag: ?[]const u8 };
    const Config = struct { item: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // null optional: key absent from encoded output, decodes back to null
    {
        const cfg = Config{ .item = .{ .name = "alice", .tag = null } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G });
        const cfg2 = try parseInto(Config, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualStrings("alice", cfg2.item.name);
        try testing.expect(cfg2.item.tag == null);
    }
    // present optional: key appears in output and decodes correctly
    {
        const cfg = Config{ .item = .{ .name = "bob", .tag = "v1" } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G });
        const cfg2 = try parseInto(Config, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualStrings("bob", cfg2.item.name);
        try testing.expectEqualStrings("v1", cfg2.item.tag.?);
    }
}

test "E5: encodeTyped empty-slice field round-trips through parse" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    const Config = struct { s: struct { push: []const []const u8 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // empty slice: encodes to no key lines; parseInto must decode back to empty slice
    const cfg = Config{ .s = .{ .push = &.{} } };
    var aw: std.Io.Writer.Allocating = .init(a);
    try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G });
    const cfg2 = try parseInto(Config, a, aw.written(), .{ .dialect = G });
    try testing.expectEqual(@as(usize, 0), cfg2.s.push.len);
    // non-empty slice still round-trips correctly
    const cfg3 = Config{ .s = .{ .push = &.{ "a", "b" } } };
    var aw3: std.Io.Writer.Allocating = .init(a);
    try encodeTyped(&aw3.writer, cfg3, a, .{ .dialect = G });
    const cfg4 = try parseInto(Config, a, aw3.written(), .{ .dialect = G });
    try testing.expectEqual(@as(usize, 2), cfg4.s.push.len);
    try testing.expectEqualStrings("a", cfg4.s.push[0]);
    try testing.expectEqualStrings("b", cfg4.s.push[1]);
}

test "E8: flat struct errors under global_keys=false dialect, passes under generic" {
    const parseInto = @import("decode.zig").parseInto;
    const Cfg = struct { name: []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Cfg{ .name = "alice" };
    // strict has global_keys=false: emitting root-level keys is unrepresentable
    {
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, cfg, a, .{ .dialect = Dialect.strict }));
    }
    // generic has global_keys=true: flat struct round-trips
    {
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = Dialect.generic });
        const cfg2 = try parseInto(Cfg, a, aw.written(), .{ .dialect = Dialect.generic });
        try testing.expectEqualStrings("alice", cfg2.name);
    }
}

test "slice element types decode accepts also encode and round-trip" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // []const bool
    {
        const Cfg = struct { s: struct { flags: []const bool } };
        const cfg = Cfg{ .s = .{ .flags = &.{ true, false, true } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqual(@as(usize, 3), back.s.flags.len);
        try testing.expectEqualSlices(bool, cfg.s.flags, back.s.flags);
    }
    // []const enum
    {
        const Color = enum { red, green, blue };
        const Cfg = struct { s: struct { c: []const Color } };
        const cfg = Cfg{ .s = .{ .c = &.{ .red, .blue } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualSlices(Color, cfg.s.c, back.s.c);
    }
    // []const i64
    {
        const Cfg = struct { s: struct { n: []const i64 } };
        const cfg = Cfg{ .s = .{ .n = &.{ 1, -2, 3 } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualSlices(i64, cfg.s.n, back.s.n);
    }
    // []const f64
    {
        const Cfg = struct { s: struct { f: []const f64 } };
        const cfg = Cfg{ .s = .{ .f = &.{ 1.5, 2.5, -3.25 } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualSlices(f64, cfg.s.f, back.s.f);
    }
    // []const []const u8
    {
        const Cfg = struct { s: struct { xs: []const []const u8 } };
        const cfg = Cfg{ .s = .{ .xs = &.{ "a", "b", "c" } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqual(@as(usize, 3), back.s.xs.len);
        for (cfg.s.xs, back.s.xs) |want, got| try testing.expectEqualStrings(want, got);
    }
}

test "nested section unrepresentable under non-subsection dialect, gitconfig round-trips" {
    const parseInto = @import("decode.zig").parseInto;
    const Cfg = struct { a: struct { b: struct { c: []const u8 } } };
    const cfg = Cfg{ .a = .{ .b = .{ .c = "deep" } } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // gitconfig can express [a "b"] so a 3-level struct round-trips.
    {
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = Dialect.gitconfig, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = Dialect.gitconfig });
        try testing.expectEqualStrings("deep", back.a.b.c);
    }
    // generic/strict have no subsection syntax: dropping b.c silently would be
    // data loss, so the encoder must reject instead.
    inline for (.{ Dialect.generic, Dialect.strict }) |d| {
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, cfg, a, .{ .dialect = d }));
    }
    // A nesting deeper than git can express (a "b" c d) is also rejected, not
    // silently truncated.
    {
        const Deep = struct { a: struct { b: struct { c: struct { d: []const u8 } } } };
        const deep = Deep{ .a = .{ .b = .{ .c = .{ .d = "x" } } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, deep, a, .{ .dialect = Dialect.gitconfig, .indent = "\t" }));
    }
}

/// Whether `sec` holds an entry whose key equals `key`. Scans entries directly
/// rather than via `Section.get`, since a key containing `.` is not a path here.
fn sectionHasKey(sec: *Section, key: []const u8) bool {
    for (sec.entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return true;
    }
    return false;
}

fn expectKeyRoundTripsOrRejected(a: std.mem.Allocator, key: []const u8, d: Dialect) !void {
    const v = try singleKeySection(a, key, "V");
    var aw: std.Io.Writer.Allocating = .init(a);
    encode(&aw.writer, v, .{ .dialect = d, .indent = "\t" }) catch |e| switch (e) {
        error.UnrepresentableValue => return, // rejected: acceptable
        else => return e,
    };
    // If it encoded, the re-parse MUST reproduce the identical key.
    const v2 = try parse(a, aw.written(), .{ .dialect = d });
    const outer = v2.section.get("s") orelse return error.SilentKeyLoss;
    if (!sectionHasKey(outer.section, key)) return error.SilentKeyCorruption;
}

test "keys that would not round-trip are rejected, never silently corrupted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // assign char embedded: splits key from value on re-parse.
    try expectKeyRoundTripsOrRejected(a, "a=b", Dialect.generic);
    try expectKeyRoundTripsOrRejected(a, "a=b", Dialect.strict);
    // ':' is an assign char only under generic.
    try expectKeyRoundTripsOrRejected(a, "a:b", Dialect.generic);
    // leading comment char: whole line becomes a comment, key vanishes.
    inline for (.{ Dialect.generic, Dialect.gitconfig }) |d| {
        try expectKeyRoundTripsOrRejected(a, "#x", d);
        try expectKeyRoundTripsOrRejected(a, ";x", d);
    }
    // leading '[': line re-parses as a (malformed) section header.
    try expectKeyRoundTripsOrRejected(a, "[x", Dialect.generic);
    // edge whitespace under trim_whitespace mutates the key.
    try expectKeyRoundTripsOrRejected(a, " x", Dialect.generic);
    try expectKeyRoundTripsOrRejected(a, "x ", Dialect.generic);

    // These must be explicitly REJECTED (not merely "either"): each corrupts.
    inline for (.{
        .{ "a=b", Dialect.generic }, .{ "a=b", Dialect.strict },
        .{ "a:b", Dialect.generic }, .{ "#x", Dialect.generic },
        .{ ";x", Dialect.gitconfig }, .{ "[x", Dialect.generic },
        .{ " x", Dialect.generic },  .{ "x ", Dialect.generic },
    }) |case| {
        const v = try singleKeySection(a, case[0], "V");
        try expectEncodeError(a, v, case[1]);
    }

    // Normal keys still encode and round-trip (including interior comment chars
    // and a dot, which is a literal key byte here, not a path separator).
    inline for (.{ "url", "good.key-name_1", "a#b", "a;b" }) |key| {
        const v = try singleKeySection(a, key, "V");
        var aw: std.Io.Writer.Allocating = .init(a);
        try encode(&aw.writer, v, .{ .dialect = Dialect.generic, .indent = "\t" });
        const v2 = try parse(a, aw.written(), .{ .dialect = Dialect.generic });
        try testing.expect(sectionHasKey(v2.section.get("s").?.section, key));
    }
    // ':' inside a key is fine under strict ('=' only) and must round-trip.
    {
        const v = try singleKeySection(a, "a:b", "V");
        var aw: std.Io.Writer.Allocating = .init(a);
        try encode(&aw.writer, v, .{ .dialect = Dialect.strict, .indent = "\t" });
        const v2 = try parse(a, aw.written(), .{ .dialect = Dialect.strict });
        try testing.expect(sectionHasKey(v2.section.get("s").?.section, "a:b"));
    }
}

test "git dialect: keys outside the git charset are UnrepresentableValue, never emitted" {
    // The git parser accepts only [A-Za-z][A-Za-z0-9-]* keys; anything else
    // fails to re-parse (error.InvalidKey). The encoder must reject such keys up
    // front rather than emit `my_key = v` that then cannot be read back.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ Dialect.gitconfig, git_indent_dialect }) |d| {
        inline for (.{ "my_key", "a.b", "a#b", "a:b", "a b", "1abc", "k_2" }) |key| {
            const v = try singleKeySection(a, key, "V");
            try expectEncodeError(a, v, d);
        }
        // Valid git keys encode and re-parse (case folds; retrieve lowercased).
        inline for (.{ .{ "k-ok", "k-ok" }, .{ "Abc", "abc" } }) |pair| {
            const v = try singleKeySection(a, pair[0], "V");
            var aw: std.Io.Writer.Allocating = .init(a);
            try encode(&aw.writer, v, .{ .dialect = d, .indent = "\t" });
            const v2 = try parse(a, aw.written(), .{ .dialect = d });
            try testing.expectEqualStrings("V", v2.get("s." ++ pair[1]).?.string);
        }
    }
}

test "git dialect: section names outside the git charset are UnrepresentableValue" {
    // Git section names use validGitSectionName (alnum, '.', '-'); '_' and space
    // fail to re-parse (MalformedSectionHeader). Reject rather than emit.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "bad_sec", "bad sec" }) |name| {
        const leaf = try a.alloc(Entry, 1);
        leaf[0] = .{ .key = "k", .value = .{ .string = "v" } };
        const inner = try a.create(Section);
        inner.* = .{ .entries = leaf };
        const outer = try a.alloc(Entry, 1);
        outer[0] = .{ .key = name, .value = .{ .section = inner } };
        const root = try a.create(Section);
        root.* = .{ .entries = outer };
        try expectEncodeError(a, .{ .section = root }, Dialect.gitconfig);
    }
    // A git-legal section name (alnum, '.', '-') encodes and round-trips.
    inline for (.{ "good-sec", "a.b" }) |name| {
        const leaf = try a.alloc(Entry, 1);
        leaf[0] = .{ .key = "k", .value = .{ .string = "v" } };
        const inner = try a.create(Section);
        inner.* = .{ .entries = leaf };
        const outer = try a.alloc(Entry, 1);
        outer[0] = .{ .key = name, .value = .{ .section = inner } };
        const root = try a.create(Section);
        root.* = .{ .entries = outer };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encode(&aw.writer, .{ .section = root }, .{ .dialect = Dialect.gitconfig, .indent = "\t" });
        _ = try parse(a, aw.written(), .{ .dialect = Dialect.gitconfig });
    }
}

test "encodeTyped: an underscore field to gitconfig is UnrepresentableValue; ini_rename escapes it" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A struct field name git cannot represent (`_`) is rejected, not emitted.
    {
        const Cfg = struct { core: struct { my_key: []const u8 } };
        const cfg = Cfg{ .core = .{ .my_key = "v" } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, cfg, a, .{ .dialect = G }));
    }
    // The escape hatch: ini_rename maps the field to a git-legal key.
    {
        const Cfg = struct {
            core: struct {
                my_key: []const u8 = "v",

                pub const ini_rename = .{ .my_key = "my-key" };
            },
        };
        const cfg = Cfg{ .core = .{} };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G });
        const cfg2 = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualStrings("v", cfg2.core.my_key);
    }
}

test "cross-dialect: a key with ':' encoded under generic is rejected, not corrupted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A strict parse accepts `a:b` as a key; re-encoding under generic (where
    // ':' is an assign char) must reject rather than emit `a:b = V`.
    const v = try singleKeySection(a, "a:b", "V");
    try expectEncodeError(a, v, Dialect.generic);
}

test "identifier gate: key/section name with newline, CR, or ] errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // key name with embedded newline
    {
        const v = try singleKeySection(a, "bad\nkey", "val");
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{}));
    }
    // key name with ]
    {
        const v = try singleKeySection(a, "bad]key", "val");
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, v, .{}));
    }
    // section name with ] closes header early
    {
        const leaf = try a.alloc(Entry, 1);
        leaf[0] = .{ .key = "k", .value = .{ .string = "v" } };
        const inner = try a.create(Section);
        inner.* = .{ .entries = leaf };
        const outer = try a.alloc(Entry, 1);
        outer[0] = .{ .key = "bad]sec", .value = .{ .section = inner } };
        const root = try a.create(Section);
        root.* = .{ .entries = outer };
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encode(&aw.writer, .{ .section = root }, .{}));
    }
    // normal identifiers must not be rejected
    {
        const v = try singleKeySection(a, "good.key-name_1", "val");
        var aw: std.Io.Writer.Allocating = .init(a);
        try encode(&aw.writer, v, .{ .dialect = Dialect.strict });
    }
}

/// encodeTyped without failing on an unrepresentable value; proves the call
/// COMPILES for the value's type and returns a runtime result rather than a
/// `@compileError`.
fn encodeTolerant(value: anytype, a: std.mem.Allocator) TypedEncodeError!void {
    var aw: std.Io.Writer.Allocating = .init(a);
    encodeTyped(&aw.writer, value, a, .{ .dialect = Dialect.gitconfig, .indent = "\t" }) catch |e| switch (e) {
        error.UnrepresentableValue => {},
        else => return e,
    };
}

test "totality: encodeTyped compiles over decode's whole slice-element surface" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Color = enum { red, green };
    const OptBool = struct { s: struct { f: []const ?bool } };
    const OptInt = struct { s: struct { f: []const ?i64 } };
    const OptEnum = struct { s: struct { f: []const ?Color } };
    const OptStr = struct { s: struct { f: []const ?[]const u8 } };
    const ListList = struct { s: struct { f: []const []const bool } };
    const ListStr = struct { s: struct { f: []const []const u8 } };
    const OptSlice = struct { s: struct { f: ?[]const bool } };
    // Every T here is one `decodeInner` compiles for; each encodeTyped
    // instantiation must compile, whether or not the value is representable.
    inline for (.{
        OptBool{ .s = .{ .f = &.{ true, null } } },
        OptInt{ .s = .{ .f = &.{ 1, 2 } } },
        OptEnum{ .s = .{ .f = &.{ .red, null } } },
        OptStr{ .s = .{ .f = &.{ "a", "b" } } },
        ListList{ .s = .{ .f = &.{ &.{true}, &.{false} } } },
        ListStr{ .s = .{ .f = &.{ "a", "b" } } },
        OptSlice{ .s = .{ .f = &.{ true, false } } },
    }) |cfg| {
        try encodeTolerant(cfg, a);
    }
}

test "slice of optionals: non-null elements round-trip, a null element is UnrepresentableValue" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // []const ?bool, all non-null: decode never yields a null element, so this
    // round-trips element-for-element.
    {
        const Cfg = struct { s: struct { f: []const ?bool } };
        const cfg = Cfg{ .s = .{ .f = &.{ true, false, true } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqual(@as(usize, 3), back.s.f.len);
        try testing.expectEqual(@as(?bool, true), back.s.f[0]);
        try testing.expectEqual(@as(?bool, false), back.s.f[1]);
        try testing.expectEqual(@as(?bool, true), back.s.f[2]);
    }
    // []const ?i64 non-null round-trips.
    {
        const Cfg = struct { s: struct { f: []const ?i64 } };
        const cfg = Cfg{ .s = .{ .f = &.{ 1, -2, 3 } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqual(@as(?i64, 1), back.s.f[0]);
        try testing.expectEqual(@as(?i64, -2), back.s.f[1]);
    }
    // []const ?[]const u8 non-null round-trips.
    {
        const Cfg = struct { s: struct { f: []const ?[]const u8 } };
        const cfg = Cfg{ .s = .{ .f = &.{ "x", "y" } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqualStrings("x", back.s.f[0].?);
        try testing.expectEqualStrings("y", back.s.f[1].?);
    }
    // A null element has no INI multi-value representation -> runtime error.
    {
        const Cfg = struct { s: struct { f: []const ?bool } };
        const cfg = Cfg{ .s = .{ .f = &.{ true, null } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" }));
    }
}

test "nested non-string slice is UnrepresentableValue; a list of strings still round-trips" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // []const []const bool: a list of lists cannot live in one flat key.
    {
        const Cfg = struct { s: struct { f: []const []const bool } };
        const cfg = Cfg{ .s = .{ .f = &.{ &.{true}, &.{ false, true } } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try testing.expectError(error.UnrepresentableValue, encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" }));
    }
    // []const []const u8 is the multi-value string case and must keep working.
    {
        const Cfg = struct { s: struct { f: []const []const u8 } };
        const cfg = Cfg{ .s = .{ .f = &.{ "a", "b", "c" } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqual(@as(usize, 3), back.s.f.len);
        try testing.expectEqualStrings("c", back.s.f[2]);
    }
}

test "optional slice field: null omits the key, present round-trips" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Cfg = struct { s: struct { f: ?[]const bool } };

    // null: no key emitted; a re-parse decodes back to null.
    {
        const cfg = Cfg{ .s = .{ .f = null } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expect(back.s.f == null);
    }
    // present: the multi-value list round-trips inside the optional.
    {
        const cfg = Cfg{ .s = .{ .f = &.{ true, false } } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expectEqual(@as(usize, 2), back.s.f.?.len);
        try testing.expectEqual(true, back.s.f.?[0]);
        try testing.expectEqual(false, back.s.f.?[1]);
    }
}

test "multi-level optional fields: ??T and ???T compile, round-trip, and omit when null" {
    const parseInto = @import("decode.zig").parseInto;
    const G = Dialect.gitconfig;
    const Color = enum { red, green };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ??bool present -> encodes and round-trips
    {
        const Cfg = struct { s: struct { flag: ??bool } };
        const cfg = Cfg{ .s = .{ .flag = @as(?bool, true) } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expect(back.s.flag != null and back.s.flag.? != null and back.s.flag.?.? == true);
    }
    // ???i64 present -> encodes and round-trips
    {
        const Cfg = struct { s: struct { num: ???i64 } };
        const cfg = Cfg{ .s = .{ .num = @as(??i64, @as(?i64, 42)) } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expect(back.s.num != null and back.s.num.? != null and back.s.num.?.? != null);
        try testing.expectEqual(@as(i64, 42), back.s.num.?.?.?);
    }
    // ??enum present -> encodes tag name and round-trips
    {
        const Cfg = struct { s: struct { c: ??Color } };
        const cfg = Cfg{ .s = .{ .c = @as(?Color, .green) } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const back = try parseInto(Cfg, a, aw.written(), .{ .dialect = G });
        try testing.expect(back.s.c != null and back.s.c.? != null);
        try testing.expectEqual(Color.green, back.s.c.?.?);
    }
    // ??bool outer null -> key absent, same as single ?T null
    {
        const Cfg = struct { s: struct { flag: ??bool, other: []const u8 } };
        const cfg = Cfg{ .s = .{ .flag = @as(??bool, null), .other = "x" } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "flag") == null);
        const back = try parseInto(Cfg, a, out, .{ .dialect = G });
        try testing.expect(back.s.flag == null);
    }
    // ??bool inner null -> key absent, same as outer null
    {
        const Cfg = struct { s: struct { flag: ??bool, other: []const u8 } };
        const cfg = Cfg{ .s = .{ .flag = @as(??bool, @as(?bool, null)), .other = "y" } };
        var aw: std.Io.Writer.Allocating = .init(a);
        try encodeTyped(&aw.writer, cfg, a, .{ .dialect = G, .indent = "\t" });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "flag") == null);
        const back = try parseInto(Cfg, a, out, .{ .dialect = G });
        try testing.expect(back.s.flag == null);
    }
}

test "totality: encodeTyped compiles over ?T/??T/???T field surface" {
    // Proves that ??T and ???T fields no longer trigger @compileError.
    // `encodeTolerant` is defined above and silences UnrepresentableValue.
    const Color = enum { red, green };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const SingleOpt = struct { s: struct { f: ?bool } };
    const DoubleOpt = struct { s: struct { f: ??bool } };
    const TripleOpt = struct { s: struct { f: ???i64 } };
    const DoubleEnum = struct { s: struct { c: ??Color } };
    inline for (.{
        SingleOpt{ .s = .{ .f = true } },
        DoubleOpt{ .s = .{ .f = @as(?bool, false) } },
        TripleOpt{ .s = .{ .f = @as(??i64, @as(?i64, 7)) } },
        DoubleEnum{ .s = .{ .c = @as(?Color, .red) } },
    }) |cfg| {
        try encodeTolerant(cfg, a);
    }
}

// sort_keys

test "sort_keys: default preserves insertion order, true sorts ascending within a section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(Entry, 3);
    entries[0] = .{ .key = "zeta", .value = .{ .string = "1" } };
    entries[1] = .{ .key = "alpha", .value = .{ .string = "2" } };
    entries[2] = .{ .key = "mid", .value = .{ .string = "3" } };
    const sec = try a.create(Section);
    sec.* = .{ .entries = entries };
    const outer = try a.alloc(Entry, 1);
    outer[0] = .{ .key = "s", .value = .{ .section = sec } };
    const root = try a.create(Section);
    root.* = .{ .entries = outer };
    const v = Value{ .section = root };

    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[s]\nzeta = 1\nalpha = 2\nmid = 3\n", aw.written());

    var aw2: std.Io.Writer.Allocating = .init(a);
    try encode(&aw2.writer, v, .{ .dialect = Dialect.strict, .sort_keys = true });
    try testing.expectEqualStrings("[s]\nalpha = 2\nmid = 3\nzeta = 1\n", aw2.written());
}

test "sort_keys: sections themselves sort ascending by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zeta_entries = try a.alloc(Entry, 1);
    zeta_entries[0] = .{ .key = "k", .value = .{ .string = "z" } };
    const zeta = try a.create(Section);
    zeta.* = .{ .entries = zeta_entries };

    const alpha_entries = try a.alloc(Entry, 1);
    alpha_entries[0] = .{ .key = "k", .value = .{ .string = "a" } };
    const alpha = try a.create(Section);
    alpha.* = .{ .entries = alpha_entries };

    const outer = try a.alloc(Entry, 2);
    outer[0] = .{ .key = "zeta", .value = .{ .section = zeta } };
    outer[1] = .{ .key = "alpha", .value = .{ .section = alpha } };
    const root = try a.create(Section);
    root.* = .{ .entries = outer };
    const v = Value{ .section = root };

    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, v, .{ .dialect = Dialect.strict, .sort_keys = true, .blank_line_between_sections = false });
    try testing.expectEqualStrings("[alpha]\nk = a\n[zeta]\nk = z\n", aw.written());
}

test "sort_keys: byte-lexicographic order (uppercase sorts before lowercase)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(Entry, 2);
    entries[0] = .{ .key = "a", .value = .{ .string = "1" } };
    entries[1] = .{ .key = "A", .value = .{ .string = "2" } };
    const sec = try a.create(Section);
    sec.* = .{ .entries = entries };
    const outer = try a.alloc(Entry, 1);
    outer[0] = .{ .key = "s", .value = .{ .section = sec } };
    const root = try a.create(Section);
    root.* = .{ .entries = outer };

    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, .{ .section = root }, .{ .dialect = Dialect.strict, .sort_keys = true });
    try testing.expectEqualStrings("[s]\nA = 2\na = 1\n", aw.written());
}

test "sort_keys: gitconfig subsections and their leaves sort recursively" {
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zeta_leaf = try a.alloc(Entry, 2);
    zeta_leaf[0] = .{ .key = "url", .value = .{ .string = "z" } };
    zeta_leaf[1] = .{ .key = "fetch", .value = .{ .string = "zf" } };
    const zeta_sec = try a.create(Section);
    zeta_sec.* = .{ .entries = zeta_leaf };

    const alpha_leaf = try a.alloc(Entry, 1);
    alpha_leaf[0] = .{ .key = "url", .value = .{ .string = "a" } };
    const alpha_sec = try a.create(Section);
    alpha_sec.* = .{ .entries = alpha_leaf };

    const remote_entries = try a.alloc(Entry, 2);
    remote_entries[0] = .{ .key = "zeta", .value = .{ .section = zeta_sec } };
    remote_entries[1] = .{ .key = "alpha", .value = .{ .section = alpha_sec } };
    const remote = try a.create(Section);
    remote.* = .{ .entries = remote_entries };

    const outer = try a.alloc(Entry, 1);
    outer[0] = .{ .key = "remote", .value = .{ .section = remote } };
    const root = try a.create(Section);
    root.* = .{ .entries = outer };

    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(&aw.writer, .{ .section = root }, .{ .dialect = G, .indent = "\t", .sort_keys = true, .blank_line_between_sections = false });
    try testing.expectEqualStrings(
        "[remote \"alpha\"]\n\turl = a\n[remote \"zeta\"]\n\tfetch = zf\n\turl = z\n",
        aw.written(),
    );
}

test "sort_keys: encodeTyped sorts fields by emitted (post-rename) key, default keeps declaration order" {
    const Cfg = struct {
        zeta: []const u8,
        alpha: []const u8,
        renamed: []const u8,

        pub const ini_rename = .{ .renamed = "aaa_first" };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = Cfg{ .zeta = "z", .alpha = "a", .renamed = "r" };

    var aw: std.Io.Writer.Allocating = .init(a);
    try encodeTyped(&aw.writer, cfg, a, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("zeta = z\nalpha = a\naaa_first = r\n", aw.written());

    var aw2: std.Io.Writer.Allocating = .init(a);
    try encodeTyped(&aw2.writer, cfg, a, .{ .dialect = Dialect.generic, .sort_keys = true });
    try testing.expectEqualStrings("aaa_first = r\nalpha = a\nzeta = z\n", aw2.written());
}
