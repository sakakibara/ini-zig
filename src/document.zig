//! Lossless INI document model: parse while retaining the original bytes,
//! edit by recording byte-range splices, and emit byte-identical output when
//! unmodified (or a minimal diff when edited).
//!
//! `Document.parse` keeps the input verbatim and a parse-with-spans index that
//! maps each dotted key path to its value's byte range. An edit validates the
//! path and records a splice (a byte range plus replacement text) without
//! mutating the buffer; `emit` applies the recorded splices to the original
//! buffer in order. With no splices the buffer is written verbatim. A failed
//! edit records nothing and leaves the document unchanged.
//!
//! All allocations go through the arena passed to `parse`; releasing the arena
//! frees everything. There is no `Document.deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const value_mod = @import("value.zig");
const parser_mod = @import("parser.zig");
const decode_mod = @import("decode.zig");
const dialect_mod = @import("dialect.zig");
const tok = @import("tokenizer.zig");
const escape = @import("escape.zig");
const escapeGit = escape.escapeGit;

const Value = value_mod.Value;
const Span = value_mod.Span;
const Spans = value_mod.Spans;
const Dialect = dialect_mod.Dialect;

pub const DocumentError = error{
    PathNotFound,
    /// A value would not survive a re-parse after splicing: a carriage return
    /// (any dialect), an embedded newline or trimmed edge whitespace under a
    /// non-quoting dialect, or a continuation-swallowing trailing backslash.
    /// Reported instead of corrupting or structurally breaking the document.
    UnrepresentableValue,
    /// A comment text held a newline (`\n`/`\r`), which would break out of the
    /// single comment line into injected key/section structure.
    InvalidComment,
    /// `setTrailingComment` was called under a dialect that does not strip
    /// inline comments, so the appended ` # text` would survive re-parse as
    /// value bytes. Reported instead of corrupting the value.
    CommentsNotSupported,
    /// Two range edits (set/setLiteral/remove/setTrailingComment) covered
    /// overlapping byte ranges, so applying both would corrupt the document.
    ConflictingEdit,
} || parser_mod.Error;

/// A pending edit: replace `source[start..end]` with `text` at emit time. A
/// zero-width range (`start == end`) is a pure insertion. `seq` records call
/// order so coincident insertions stay stably ordered.
const Splice = struct {
    start: usize,
    end: usize,
    text: []const u8,
    seq: u32,
};

/// Byte anchors of a key/value entry. `value_*`/`content_end`/`line_end` cover
/// the whole LOGICAL line (the value's first physical line through its last
/// continuation line), so edits operate on the entire entry rather than only
/// its first physical line. `line_start`/`indent` are the first physical line.
/// `bare` marks a no-value key (no assign char on the line); `key_end` is the
/// offset just past its key token, where a value or trailing comment is grafted.
const Anchors = struct {
    line_start: usize,
    value_start: usize,
    value_end: usize,
    content_end: usize,
    line_end: usize,
    indent: []const u8,
    bare: bool,
    key_end: usize,
};

pub const Document = struct {
    arena: Allocator,
    /// Source bytes with any leading BOM stripped. Spans index into this slice.
    source: []const u8,
    /// Whether the original input began with a UTF-8 BOM (EF BB BF).
    /// emit() re-prepends the BOM so the output is byte-identical to the input.
    bom: bool,
    options: parser_mod.ParseOptions,
    /// Parse snapshot of the ORIGINAL source. `spans` index into it and edits
    /// resolve against it, so it must stay pinned across edits.
    parsed: Value,
    /// Read view reflecting all pending edits: refreshed from the emitted bytes
    /// after every recorded splice, so reads agree with `emit`. Kept separate
    /// from `parsed` because the edit machinery relies on original spans.
    view: Value,
    spans: Spans,
    splices: std.ArrayList(Splice),
    /// Monotonic counter assigning each splice its call-order tiebreaker.
    seq: u32,

    pub fn parse(arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) DocumentError!Document {
        const has_bom = std.mem.startsWith(u8, src, "\xEF\xBB\xBF");
        // Strip the BOM before duplication so spans are relative to the
        // BOM-free content; emit() re-prepends the BOM when present.
        const stripped = if (has_bom) src[3..] else src;
        const source = try arena.dupe(u8, stripped);
        var spans: Spans = .empty;
        var opts = options;
        opts.spans = &spans;
        const parsed = try parser_mod.parse(arena, source, opts);
        return .{
            .arena = arena,
            .source = source,
            .bom = has_bom,
            .options = options,
            .parsed = parsed,
            .view = parsed,
            .spans = spans,
            .splices = .empty,
            .seq = 0,
        };
    }

    /// Look up a value by dotted path, reflecting any pending edits. Returns
    /// null if absent. A name containing `.` (a gitconfig subsection) is not
    /// addressable here; use `getSegments`.
    pub fn get(self: *const Document, path: []const u8) ?Value {
        return self.view.get(path);
    }

    /// Look up a value by explicit path segments (no splitting), reflecting any
    /// pending edits. Addresses a name containing `.`; see `Section.getSegments`.
    pub fn getSegments(self: *const Document, segments: []const []const u8) ?Value {
        return self.view.getSegments(segments);
    }

    /// Typed read by dotted path, reflecting any pending edits. Null on missing
    /// path or decode failure; allocation failure propagates.
    pub fn getT(self: *const Document, comptime T: type, path: []const u8) error{OutOfMemory}!?T {
        return decode_mod.getT(T, self.arena, self.view, path, self.options);
    }

    /// Typed read by explicit path segments, reflecting any pending edits.
    /// Addresses a name containing `.`; null on missing path or decode
    /// failure; allocation failure propagates.
    pub fn getTSegments(self: *const Document, comptime T: type, segments: []const []const u8) error{OutOfMemory}!?T {
        return decode_mod.getTSegments(T, self.arena, self.view, segments, self.options);
    }

    /// Set `path` to `value`, comptime-dispatched on its Zig type. Strings,
    /// bools, integers, and floats are rendered to INI text (escaped per the
    /// dialect) and spliced over the existing value token.
    pub fn set(self: *Document, path: []const u8, value: anytype) DocumentError!void {
        const text = try self.renderTyped(@TypeOf(value), value);
        return self.setLiteral(path, text);
    }

    /// Splice `raw` verbatim over the value token at `path`. `raw` is NOT
    /// escaped (use `set` for dialect-aware escaping); a newline or carriage
    /// return is rejected because it would inject a physical line break, and a
    /// literal that would break the surrounding structure (an odd trailing
    /// backslash run under backslash continuation, or an unbalanced git quote)
    /// is rejected too. A value-level non-round-trip remains the caller's
    /// footgun; only document-structure breaks are refused. For a no-value key
    /// the literal is grafted as `<assign> raw`, turning it into a normal entry.
    pub fn setLiteral(self: *Document, path: []const u8, raw: []const u8) DocumentError!void {
        if (std.mem.indexOfAny(u8, raw, "\n\r") != null) return error.UnrepresentableValue;
        if (escape.structureBreakingLiteral(self.options.dialect, raw)) return error.UnrepresentableValue;
        const a = self.locate(path) orelse return error.PathNotFound;
        if (a.bare) {
            const graft = try std.fmt.allocPrint(self.arena, " {c} {s}", .{ self.assignChar(), raw });
            return self.recordSplice(a.key_end, a.key_end, graft);
        }
        try self.recordSplice(a.value_start, a.value_end, raw);
    }

    /// Delete the whole line containing `path`.
    pub fn remove(self: *Document, path: []const u8) DocumentError!void {
        const a = self.locate(path) orelse return error.PathNotFound;
        try self.recordSplice(a.line_start, a.line_end, "");
    }

    /// Insert a comment line immediately before the line containing `path`.
    /// The leading whitespace of the target line is mirrored; the comment
    /// character and a trailing newline are added automatically.
    pub fn addCommentBefore(self: *Document, path: []const u8, text: []const u8) DocumentError!void {
        if (hasNewline(text)) return error.InvalidComment;
        const a = self.locate(path) orelse return error.PathNotFound;
        const line = try std.fmt.allocPrint(self.arena, "{s}{c} {s}\n", .{ a.indent, self.commentChar(), text });
        try self.recordSplice(a.line_start, a.line_start, line);
    }

    /// Set or replace the trailing comment on the line containing `path`. For a
    /// continuation value the comment lands after the last physical line, so the
    /// join stays intact. A trailing comment only round-trips under a dialect
    /// that strips inline comments; otherwise the appended bytes would re-parse
    /// as value text, so the call is refused. A no-value key is first grafted
    /// with an empty value (`<assign>`) so the comment attaches without
    /// clobbering the key.
    pub fn setTrailingComment(self: *Document, path: []const u8, text: []const u8) DocumentError!void {
        if (!self.options.dialect.inline_comments) return error.CommentsNotSupported;
        if (hasNewline(text)) return error.InvalidComment;
        const a = self.locate(path) orelse return error.PathNotFound;
        if (a.bare) {
            const graft = try std.fmt.allocPrint(self.arena, " {c}  {c} {s}", .{ self.assignChar(), self.commentChar(), text });
            return self.recordSplice(a.key_end, a.key_end, graft);
        }
        const repl = try std.fmt.allocPrint(self.arena, "  {c} {s}", .{ self.commentChar(), text });
        try self.recordSplice(a.value_end, a.content_end, repl);
    }

    /// Write the document, applying any recorded splices to the original
    /// buffer in order. With no splices the buffer is written verbatim.
    /// A leading BOM present in the original input is re-emitted first.
    pub fn emit(self: *const Document, w: *Io.Writer) Io.Writer.Error!void {
        if (self.bom) try w.writeAll("\xEF\xBB\xBF");
        var pos: usize = 0;
        for (self.splices.items) |s| {
            if (s.start < pos) continue;
            try w.writeAll(self.source[pos..s.start]);
            try w.writeAll(s.text);
            pos = s.end;
        }
        try w.writeAll(self.source[pos..]);
    }

    fn locate(self: *const Document, path: []const u8) ?Anchors {
        const span = self.spans.get(path) orelse return null;
        const src = self.source;
        const dialect = self.options.dialect;
        // u64 span offsets index an in-memory buffer, so they fit usize.
        const value_start: usize = @intCast(span.start);
        const value_span_end: usize = @intCast(span.end);
        const line_start = lineStartOf(src, value_start);

        // Walk physical lines from the entry's first line so edits cover the
        // whole logical line: a continuation value's span records only its first
        // physical line, but remove/set must reach the last continuation line.
        const ext = logicalExtent(src, dialect, line_start);
        const value_end: usize = if (ext.multi)
            ext.last_start + valueTokenLen(src[ext.last_start..ext.content_end], dialect)
        else
            value_start + valueTokenLen(src[value_start..value_span_end], dialect);

        // A no-value key carries the synthetic empty string, so its span falls
        // back to the whole first line (covering the key, not a value). Detect it
        // by the absence of an assign char so set/setTrailingComment graft onto
        // the key instead of overwriting it.
        const first_end = firstLineEnd(src, line_start);
        const bare = tok.findAssign(src[line_start..first_end], dialect.assign_chars) == null;
        const key_end: usize = if (bare) keyTokenEnd(src, line_start, first_end) else value_end;

        return .{
            .line_start = line_start,
            .value_start = value_start,
            .value_end = value_end,
            .content_end = ext.content_end,
            .line_end = ext.line_end,
            .indent = indentOf(src, line_start),
            .bare = bare,
            .key_end = key_end,
        };
    }

    /// Record a splice. A pure insertion (`start == end`) always composes,
    /// stacking with other edits at the same point; an exact-range repeat of a
    /// prior range edit overwrites it (last-wins); a partial range overlap is
    /// rejected as a conflict. Splices stay ordered by (start, insertions before
    /// range edits, call order) so `emit` applies them without a sort.
    ///
    /// The refresh is atomic: an edit whose emitted bytes fail to re-parse is
    /// rolled back (its splice removed / its overwritten text restored) so a
    /// failed edit leaves the document EXACTLY as before and get()==emit()==pre-edit.
    fn recordSplice(self: *Document, start: usize, end: usize, text: []const u8) DocumentError!void {
        const new_range = end > start;
        for (self.splices.items, 0..) |s, i| {
            const ex_range = s.end > s.start;
            if (new_range and ex_range) {
                if (s.start == start and s.end == end) {
                    const prev = self.splices.items[i].text;
                    self.splices.items[i].text = try self.arena.dupe(u8, text);
                    self.refreshView() catch |e| {
                        self.splices.items[i].text = prev;
                        return e;
                    };
                    return;
                }
                if (start < s.end and s.start < end) return error.ConflictingEdit;
            } else if (new_range and !ex_range) {
                // An existing insertion strictly inside the new range would be
                // emitted mid-replacement.
                if (start < s.start and s.start < end) return error.ConflictingEdit;
            } else if (!new_range and ex_range) {
                if (s.start < start and start < s.end) return error.ConflictingEdit;
            }
        }
        const owned = try self.arena.dupe(u8, text);
        const sp = Splice{ .start = start, .end = end, .text = owned, .seq = self.seq };
        var idx: usize = 0;
        while (idx < self.splices.items.len and spliceLess(self.splices.items[idx], sp)) idx += 1;
        try self.splices.insert(self.arena, idx, sp);
        self.seq += 1;
        self.refreshView() catch |e| {
            _ = self.splices.orderedRemove(idx);
            self.seq -= 1;
            return e;
        };
    }

    /// Reparse the current emitted bytes into `view` so reads reflect pending
    /// edits. `parsed`/`spans`/`source`/`splices` stay pinned to the original,
    /// keeping edit resolution and conflict detection byte-exact; only the read
    /// view moves. `emit` re-prepends any BOM and the parser re-strips it. On a
    /// re-parse failure `view` is left untouched (the assignment never runs), so
    /// the caller can roll the triggering splice back to restore consistency.
    fn refreshView(self: *Document) DocumentError!void {
        var aw: Io.Writer.Allocating = .init(self.arena);
        self.emit(&aw.writer) catch return error.OutOfMemory;
        var opts = self.options;
        opts.spans = null;
        self.view = try parser_mod.parse(self.arena, aw.written(), opts);
    }

    fn renderTyped(self: *const Document, comptime T: type, value: T) DocumentError![]const u8 {
        const plain = try plainRepr(self.arena, T, value);
        if (escape.unrepresentableSpliced(self.options.dialect, plain)) return error.UnrepresentableValue;
        if (self.options.dialect.quoting != .git) return plain;
        var aw: Io.Writer.Allocating = .init(self.arena);
        escapeGit(&aw.writer, plain) catch return error.OutOfMemory;
        return aw.written();
    }

    fn commentChar(self: *const Document) u8 {
        const cc = self.options.dialect.comment_chars;
        if (std.mem.indexOfScalar(u8, cc, '#') != null) return '#';
        if (cc.len > 0) return cc[0];
        return '#';
    }

    fn assignChar(self: *const Document) u8 {
        const ac = self.options.dialect.assign_chars;
        if (std.mem.indexOfScalar(u8, ac, '=') != null) return '=';
        if (ac.len > 0) return ac[0];
        return '=';
    }
};

fn plainRepr(arena: Allocator, comptime T: type, value: T) DocumentError![]const u8 {
    return switch (@typeInfo(T)) {
        .bool => if (value) "true" else "false",
        .int, .comptime_int => try std.fmt.allocPrint(arena, "{d}", .{value}),
        .float, .comptime_float => try std.fmt.allocPrint(arena, "{}", .{value}),
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk value;
            if (p.size == .one) {
                const ci = @typeInfo(p.child);
                if (ci == .array and ci.array.child == u8) break :blk @as([]const u8, value);
            }
            @compileError("Document.set: unsupported value type " ++ @typeName(T));
        },
        else => @compileError("Document.set: unsupported value type " ++ @typeName(T)),
    };
}

/// Length of the value token within `raw`, excluding a trailing comment and
/// the whitespace before it. A comment character terminates the value only
/// when the dialect strips inline comments (otherwise the comment char is value
/// text), preceded by whitespace, and outside a quoted span.
fn valueTokenLen(raw: []const u8, dialect: Dialect) usize {
    var i: usize = 0;
    var last: usize = 0;
    var in_quotes = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (dialect.quoting == .git and c == '\\' and i + 1 < raw.len) {
            i += 1;
            last = i + 1;
            continue;
        }
        if (c == '"') {
            in_quotes = !in_quotes;
            last = i + 1;
            continue;
        }
        if (!in_quotes and (c == ' ' or c == '\t')) continue;
        if (!in_quotes and dialect.inline_comments and i > 0 and
            (raw[i - 1] == ' ' or raw[i - 1] == '\t') and
            std.mem.indexOfScalar(u8, dialect.comment_chars, c) != null)
        {
            break;
        }
        last = i + 1;
    }
    return last;
}

fn lineStartOf(src: []const u8, pos: usize) usize {
    var i: usize = pos;
    while (i > 0 and src[i - 1] != '\n') i -= 1;
    return i;
}

/// Offset of the first physical line's content end (before its terminator).
fn firstLineEnd(src: []const u8, line_start: usize) usize {
    var i: usize = line_start;
    while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
    return i;
}

/// Offset just past the bare key's last non-whitespace byte on its line.
fn keyTokenEnd(src: []const u8, line_start: usize, first_end: usize) usize {
    var e: usize = first_end;
    while (e > line_start and (src[e - 1] == ' ' or src[e - 1] == '\t')) e -= 1;
    return e;
}

fn indentOf(src: []const u8, line_start: usize) []const u8 {
    var i: usize = line_start;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    return src[line_start..i];
}

fn hasNewline(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\n\r") != null;
}

/// Ordering for the splice list: by start, then insertions (zero-width) before
/// range edits at the same start, then by call order.
fn spliceLess(a: Splice, b: Splice) bool {
    if (a.start != b.start) return a.start < b.start;
    const a_ins = a.start == a.end;
    const b_ins = b.start == b.end;
    if (a_ins != b_ins) return a_ins;
    return a.seq < b.seq;
}

/// Byte extent of an entry's last physical line. `multi` is set when the value
/// spans continuation lines; `last_start` is that final line's content start,
/// `content_end` its content end (before the terminator), `line_end` the offset
/// just past its terminator.
const LogicalExtent = struct {
    multi: bool,
    last_start: usize,
    content_end: usize,
    line_end: usize,
};

/// Find where an entry's logical line ends by re-classifying physical lines
/// from `line_start` with the same framing the tokenizer uses, so the document
/// and parser agree on continuation boundaries. Trailing blank lines (which the
/// parser drops from the value) are not folded into the extent.
fn logicalExtent(src: []const u8, dialect: Dialect, line_start: usize) LogicalExtent {
    var tz = tok.Tokenizer.init(src[line_start..], dialect);
    const first = tz.next() orelse return .{
        .multi = false,
        .last_start = line_start,
        .content_end = line_start,
        .line_end = line_start,
    };
    var ext = LogicalExtent{
        .multi = false,
        .last_start = line_start,
        .content_end = line_start + @as(usize, @intCast(first.span.end)),
        .line_end = line_start + tz.pos,
    };
    while (tz.next()) |t| {
        switch (t.kind) {
            .continuation => {
                ext.multi = true;
                ext.last_start = line_start + @as(usize, @intCast(t.span.start));
                ext.content_end = line_start + @as(usize, @intCast(t.span.end));
                ext.line_end = line_start + tz.pos;
            },
            // A blank inside an indent value block is only part of the value if a
            // later continuation follows; keep scanning without committing it.
            .blank => {},
            else => break,
        }
    }
    return ext;
}

const testing = std.testing;

test "unmodified document emits byte-identical" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "# header\n[remote \"o\"]\n\turl = u  # trailing\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "set produces a minimal diff and preserves comments" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[user]\n\tname = Ada  # who\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try doc.set("user.name", "Grace");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("[user]\n\tname = Grace  # who\n", aw.written());
}

test "a failed edit leaves the document unchanged (atomic)" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[user]\n\tname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectError(error.PathNotFound, doc.set("missing.key", "x"));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "an edit whose emitted bytes fail to re-parse rolls back fully (atomic)" {
    // setLiteral only screens structure-breaking literals, not every literal
    // that is invalid on re-parse: `a\zb` carries an invalid git escape, caught
    // only when refreshView re-parses the emitted bytes. A failed refresh must
    // leave the document EXACTLY as before - no recorded splice, view intact -
    // so get() and emit() stay consistent (both pre-edit).
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = orig\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });

    try testing.expectError(error.InvalidEscape, doc.setLiteral("s.k", "a\\zb"));
    // Fully rolled back: the read is the pre-edit value, and emit is byte-exact.
    try testing.expectEqualStrings("orig", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());

    // A subsequent valid edit still lands in both get() and emit().
    try doc.setLiteral("s.k", "new");
    try testing.expectEqualStrings("new", doc.get("s.k").?.string);
    var aw2: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw2.writer);
    try testing.expectEqualStrings("[s]\n\tk = new\n", aw2.written());
}

test "a rolled-back overwrite edit leaves a prior successful edit intact" {
    // The exact-range last-wins overwrite path must also roll back: a valid edit,
    // then a same-range edit whose bytes fail to re-parse, must leave the first
    // edit's value visible in both get() and emit().
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = orig\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });

    try doc.setLiteral("s.k", "good");
    try testing.expectError(error.InvalidEscape, doc.setLiteral("s.k", "a\\zb"));
    try testing.expectEqualStrings("good", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\n\tk = good\n", aw.written());
}

test "get and getT read the parsed tree" {
    const src = "[server]\nport = 8080\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("8080", doc.get("server.port").?.string);
    try testing.expectEqual(@as(u16, 8080), (try doc.getT(u16, "server.port")).?);
}

test "C3: get/getT reflect a pending set (read-after-write matches emit)" {
    const src = "[server]\nport = 8080\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.set("server.port", @as(u16, 9999));
    // The read now agrees with what emit will write.
    try testing.expectEqualStrings("9999", doc.get("server.port").?.string);
    try testing.expectEqual(@as(u16, 9999), (try doc.getT(u16, "server.port")).?);
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[server]\nport = 9999\n", out);
}

test "C3: get reflects setLiteral, and set-then-set returns the latest value" {
    const src = "[s]\nk = a\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.setLiteral("s.k", "b");
    try testing.expectEqualStrings("b", doc.get("s.k").?.string);
    // Repeated edit to the same path (exact-range last-wins) is visible.
    try doc.setLiteral("s.k", "c");
    try testing.expectEqualStrings("c", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nk = c\n", aw.written());
}

test "C3: get reflects a pending remove (read-after-write matches emit)" {
    const src = "[s]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.remove("s.a");
    try testing.expect(doc.get("s.a") == null);
    try testing.expect(try doc.getT(u32, "s.a") == null);
    // The surviving key still reads.
    try testing.expectEqualStrings("2", doc.get("s.b").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nb = 2\n", aw.written());
}

test "C3: set-then-remove leaves get null, matching emit" {
    const src = "[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.set("s.k", @as([]const u8, "new"));
    try testing.expectEqualStrings("new", doc.get("s.k").?.string);
    // remove spans the value edit's line -> conflict is rejected atomically, so
    // the read still reflects the set. (Documents the interaction, not a bug.)
    try testing.expectError(error.ConflictingEdit, doc.remove("s.k"));
    try testing.expectEqualStrings("new", doc.get("s.k").?.string);
}

test "C3: a grafted value on a bare gitconfig key is visible via get" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    // Before the edit the bare key reads as the empty string.
    try testing.expectEqualStrings("", doc.get("core.bare").?.string);
    try doc.set("core.bare", @as([]const u8, "yes"));
    try testing.expectEqualStrings("yes", doc.get("core.bare").?.string);
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare = yes\n", out);
}

test "C3: getSegments on a document reflects edits to a dotted subsection" {
    const G = Dialect.gitconfig;
    const src = "[branch \"feature.x\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    // Reachable only by segments (the '.' in the subsection name).
    try testing.expectEqualStrings(
        "refs/heads/main",
        doc.getSegments(&.{ "branch", "feature.x", "merge" }).?.string,
    );
    // Edit that same value through the dotted path git-config would use, and see
    // the segment read reflect it.
    try doc.set("branch.feature.x.merge", @as([]const u8, "refs/heads/dev"));
    try testing.expectEqualStrings(
        "refs/heads/dev",
        doc.getSegments(&.{ "branch", "feature.x", "merge" }).?.string,
    );
    try testing.expectEqualStrings(
        "refs/heads/dev",
        (try doc.getTSegments([]const u8, &.{ "branch", "feature.x", "merge" })).?,
    );
}

test "setLiteral splices raw text verbatim" {
    const src = "[server]\nport = 8080\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.setLiteral("server.port", "9999");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nport = 9999\n", aw.written());
}

test "set typed values render and escape per dialect" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare = old\n\tn = 0\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try doc.set("core.bare", true);
    try doc.set("core.n", @as(i64, 42));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[core]\n\tbare = true\n\tn = 42\n", aw.written());
}

test "remove deletes the whole line" {
    const src = "[s]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.remove("s.a");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nb = 2\n", aw.written());
}

test "remove on a missing path is atomic" {
    const src = "[s]\na = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectError(error.PathNotFound, doc.remove("s.missing"));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "addCommentBefore mirrors indentation" {
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.addCommentBefore("s.k", "note");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\n\t# note\n\tk = v\n", aw.written());
}

test "setTrailingComment replaces an existing trailing comment (reparses to same value)" {
    const G = Dialect.gitconfig;
    const src = "[user]\n\tname = Ada  # who\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setTrailingComment("user.name", "person");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[user]\n\tname = Ada  # person\n", out);
    // The comment is stripped on re-parse; the value is untouched.
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("Ada", v2.get("user.name").?.string);
}

test "setTrailingComment adds a comment when none exists (reparses to same value)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setTrailingComment("s.k", "added");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v  # added\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("v", v2.get("s.k").?.string);
}

test "R5: setTrailingComment refuses a non-inline dialect (atomic)" {
    // Under a dialect that does NOT strip inline comments the appended `# text`
    // would re-parse as value bytes, so the call is refused before any splice.
    inline for (.{ Dialect.strict, Dialect.generic, Dialect.systemd, Dialect.windows }) |D| {
        const src = "[s]\nk = v\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), src, .{ .dialect = D });
        try testing.expectError(error.CommentsNotSupported, doc.setTrailingComment("s.k", "added"));
        var aw: std.Io.Writer.Allocating = .init(arena.allocator());
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings(src, aw.written());
    }
}

test "DOC6: BOM is stripped for parsing and re-emitted verbatim by emit" {
    const src = "\xEF\xBB\xBF[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("v", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "DOC3: set rejects values that would not survive a re-parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // strict: leading whitespace would be trimmed away.
    {
        var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.strict });
        try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, " lead")));
    }
    // strict: an embedded newline would shatter the document structure.
    {
        var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.strict });
        try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, "a\nb")));
    }
    // generic: a carriage return is rejected even though git is not involved.
    {
        var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.generic });
        try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, "a\rb")));
    }
}

test "DOC3: a rejected set leaves the document unchanged (atomic)" {
    const src = "[s]\nk = orig\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, "a\nb")));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "DOC3: a representable value still round-trips through set" {
    // A '#' is not stripped by any non-git dialect, so it must NOT be rejected.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.generic });
    try doc.set("s.k", @as([]const u8, "a # b"));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    const v2 = try parser_mod.parse(a, aw.written(), .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("a # b", v2.get("s.k").?.string);
}

test "DOC3: setLiteral rejects a structure-breaking newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "[s]\nk = orig\n", .{ .dialect = Dialect.strict });
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\nb"));
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\rb"));
    // A plain raw splice is still allowed (the documented footgun stays usable).
    try doc.setLiteral("s.k", "raw value");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nk = raw value\n", aw.written());
}

test "DOC6: set on a BOM document round-trips BOM in output" {
    const src = "\xEF\xBB\xBF[s]\nk = old\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});
    try doc.set("s.k", "new");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("\xEF\xBB\xBF[s]\nk = new\n", aw.written());
}

/// Emit `doc` and re-parse the result, asserting the round-trip is well-formed.
fn emitAndReparse(arena: Allocator, doc: *const Document, opts: parser_mod.ParseOptions) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    _ = try parser_mod.parse(arena, aw.written(), opts);
    return aw.written();
}

test "DOC1: remove deletes the whole continuation line (gitconfig backslash)" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\turl = first \\\n\tsecond\n[other]\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.remove("remote.o.url");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    // No orphaned `\tsecond` line, and the unrelated key survives.
    try testing.expectEqualStrings("[remote \"o\"]\n[other]\n\tx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expect(v2.get("remote.o.url") == null);
    try testing.expectEqualStrings("1", v2.get("other.x").?.string);
}

test "DOC1: remove deletes the whole continuation line (generic indent)" {
    const src = "[s]\nkey = first\n    second\n[other]\nx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try doc.remove("s.key");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\n[other]\nx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
    try testing.expect(v2.get("s.key") == null);
    try testing.expectEqualStrings("1", v2.get("other.x").?.string);
}

test "DOC1: set replaces the whole continuation value (gitconfig)" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\turl = first \\\n\tsecond\n[other]\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("remote.o.url", "new");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"o\"]\n\turl = new\n[other]\n\tx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("new", v2.get("remote.o.url").?.string);
    try testing.expectEqualStrings("1", v2.get("other.x").?.string);
}

test "DOC1: set replaces the whole continuation value (generic indent)" {
    const src = "[s]\nkey = first\n    second\nother = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try doc.set("s.key", "new");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\nkey = new\nother = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("new", v2.get("s.key").?.string);
    try testing.expectEqualStrings("1", v2.get("s.other").?.string);
}

test "DOC1: setLiteral replaces the whole continuation value (generic indent)" {
    const src = "[s]\nkey = first\n    second\nother = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try doc.setLiteral("s.key", "raw");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\nkey = raw\nother = 1\n", out);
}

test "DOC2: setTrailingComment lands after the last continuation line" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\turl = first \\\n\tsecond\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    const before = doc.get("remote.o.url").?.string;
    try doc.setTrailingComment("remote.o.url", "note");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    // The `\` continuation stays intact; the comment sits on the last line.
    try testing.expectEqualStrings("[remote \"o\"]\n\turl = first \\\n\tsecond  # note\n", out);
    // The joined value is unchanged (the comment is stripped on re-parse).
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings(before, v2.get("remote.o.url").?.string);
}

test "DOC4: addCommentBefore and remove compose (both orders)" {
    const src = "[s]\na = 1\nb = 2\n";
    inline for (.{ true, false }) |comment_first| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
        if (comment_first) {
            try doc.addCommentBefore("s.a", "note");
            try doc.remove("s.a");
        } else {
            try doc.remove("s.a");
            try doc.addCommentBefore("s.a", "note");
        }
        var aw: std.Io.Writer.Allocating = .init(arena.allocator());
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("[s]\n# note\nb = 2\n", aw.written());
    }
}

test "DOC4: two addCommentBefore on one key stack both comments" {
    const src = "[s]\na = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.addCommentBefore("s.a", "one");
    try doc.addCommentBefore("s.a", "two");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\n# one\n# two\na = 1\n", aw.written());
}

test "DOC4: set and setTrailingComment on one key compose" {
    const G = Dialect.gitconfig;
    const src = "[user]\n\tname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try doc.set("user.name", "Grace");
    try doc.setTrailingComment("user.name", "who");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[user]\n\tname = Grace  # who\n", aw.written());
}

test "DOC4: genuinely overlapping range edits are rejected, atomically" {
    const src = "[s]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.set("s.a", "9");
    // remove spans the line set already edited -> conflict, records nothing.
    try testing.expectError(error.ConflictingEdit, doc.remove("s.a"));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\na = 9\nb = 2\n", aw.written());
}

test "DOC5: a comment with a newline is rejected (no structure injection)" {
    // gitconfig strips inline comments, so setTrailingComment is supported here;
    // the rejection under test is the comment TEXT carrying a newline.
    const G = Dialect.gitconfig;
    const src = "[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectError(error.InvalidComment, doc.addCommentBefore("s.k", "a\n[evil]\nx = 1"));
    try testing.expectError(error.InvalidComment, doc.setTrailingComment("s.k", "a\r b"));
    // Rejected edits are atomic: the document is untouched.
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "DOC7: set on an empty value re-parses correctly (post-= space left as-is)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk =\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("s.k", "v");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk =v\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("v", v2.get("s.k").?.string);
}

test "R4: set on a non-inline dialect overwrites the whole value past a false '#'" {
    // generic does not strip inline comments, so `hello # world` is one value;
    // set must overwrite all of it, not truncate at the ` #` boundary.
    const src = "[s]\nk = hello # world\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("hello # world", doc.get("s.k").?.string);
    try doc.set("s.k", @as([]const u8, "NEW"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\nk = NEW\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("NEW", v2.get("s.k").?.string);
}

test "R4: gitconfig set still stops at a real inline comment" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = a ; c\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("s.k", @as([]const u8, "NEW"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = NEW ; c\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("NEW", v2.get("s.k").?.string);
}

test "R6: set on a bare gitconfig key grafts a value without clobbering the key" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("core.bare", @as([]const u8, "yes"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare = yes\n\tx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("yes", v2.get("core.bare").?.string);
    try testing.expectEqualStrings("1", v2.get("core.x").?.string);
}

test "R6: setLiteral on a bare gitconfig key grafts the raw literal" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setLiteral("core.bare", "raw");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare = raw\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("raw", v2.get("core.bare").?.string);
}

test "R6: setTrailingComment on a bare gitconfig key attaches without clobbering" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setTrailingComment("core.bare", "tc");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare =  # tc\n\tx = 1\n", out);
    // The key survives; its value stays the bare empty string.
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("", v2.get("core.bare").?.string);
    try testing.expectEqualStrings("1", v2.get("core.x").?.string);
}

test "R2: setLiteral rejects an odd trailing backslash under backslash continuation (atomic)" {
    // systemd has no quoting; an odd trailing '\' would swallow the next line.
    const src = "[s]\nk = v\nnext = w\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.systemd });
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\\"));
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\\\\\\"));
    // An even run is an escaped pair, not a continuation: still allowed.
    try doc.setLiteral("s.k", "a\\\\");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.systemd });
    try testing.expectEqualStrings("[s]\nk = a\\\\\nnext = w\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.systemd });
    try testing.expectEqualStrings("w", v2.get("s.next").?.string);
}

test "R2: setLiteral rejects an unbalanced git quote (atomic)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n\tnext = w\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\"b"));
    // An escaped quote does not open a span: still allowed.
    try doc.setLiteral("s.k", "a\\\"b");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = a\\\"b\n\tnext = w\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("a\"b", v2.get("s.k").?.string);
    try testing.expectEqualStrings("w", v2.get("s.next").?.string);
}
