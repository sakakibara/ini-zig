//! INI value types, section model, and dotted-path navigation.
//!
//! `Value` is a tagged union covering the three kinds an INI leaf can hold:
//! a raw string, a multi-value list (same key repeated), or a nested Section
//! pointer. Values are never type-inferred here -- they stay raw strings.
//!
//! Memory model: Section/Value/Entry are built in a caller-owned arena; all
//! string slices point into the parse source or are arena-allocated. The one
//! exception is `getAll`, which allocates a fresh outer slice from a
//! caller-supplied allocator; the caller frees it with `gpa.free(result.?)`.

const std = @import("std");
const testing = std.testing;

/// 1-indexed line/column derived from a byte offset. Produced by `Span.lineCol`.
pub const LineCol = struct {
    line: u32,
    col: u32,
};

/// Source byte range of a parsed token, as offsets into the input buffer.
/// Offsets are u64, so a span addresses any in-memory `[]const u8` without a
/// 4 GiB cap. Line/column are not stored; derive them on demand with `lineCol`.
pub const Span = struct {
    start: u64,
    end: u64,

    /// 1-indexed line and column of `start` within `src`. O(start): scans
    /// `src[0..start]` counting newlines. Intended for occasional human-facing
    /// location display (diagnostics, tooling), not bulk per-value use. Column
    /// is the byte count since the last newline, plus one. Both saturate at
    /// `maxInt(u32)` for absurdly large inputs.
    pub fn lineCol(self: Span, src: []const u8) LineCol {
        const limit: usize = @intCast(@min(self.start, src.len));
        var line: u64 = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{
            .line = std.math.cast(u32, line) orelse std.math.maxInt(u32),
            .col = std.math.cast(u32, limit - line_start + 1) orelse std.math.maxInt(u32),
        };
    }
};

/// Path -> source span map, populated when span tracking is enabled.
pub const Spans = std.StringHashMapUnmanaged(Span);

/// A single key/value pair inside a Section.
pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// Dynamic INI value. Strings are raw (no type inference).
pub const Value = union(enum) {
    /// A scalar string value.
    string: []const u8,
    /// A multi-value list from repeated keys; elements are in order of appearance.
    list: []const []const u8,
    /// A nested section (e.g. [section "subsection"] in gitconfig style).
    section: *Section,

    /// Navigate a dotted path from this value. Resolves to the named leaf
    /// when this value is a section; any other variant has no children, so
    /// a non-empty path yields null.
    ///
    /// A name that itself contains `.` (e.g. a gitconfig subsection like
    /// `[branch "feature.x"]`) is NOT reachable through the dotted API,
    /// since the `.` is read as a separator. Use `getSegments` for those.
    pub fn get(self: Value, path: []const u8) ?Value {
        return switch (self) {
            .section => |s| s.get(path),
            else => null,
        };
    }

    /// Navigate by explicit path segments, with NO splitting. Each segment is
    /// matched verbatim, so a name containing `.` is addressable. Resolves only
    /// when this value is a section.
    pub fn getSegments(self: Value, segments: []const []const u8) ?Value {
        return switch (self) {
            .section => |s| s.getSegments(segments),
            else => null,
        };
    }
};

/// Paired result of `locate`: the value at a path plus its source span.
pub const LocateResult = struct {
    value: Value,
    span: Span,
};

/// An INI section: an ordered slice of key/value entries.
///
/// Entries preserve insertion order. Duplicate keys accumulate as a `.list`
/// (the parser's job); `get` returns the stored `Value` as-is.
pub const Section = struct {
    entries: []Entry,

    /// Value stored under `key` in this section's own entries, or null.
    /// `key` is matched verbatim against the stored (already case-folded)
    /// bytes; it is a single name, not a dotted path.
    pub fn findValue(self: Section, key: []const u8) ?Value {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    /// Walk a dotted path and return the stored `Value`, or null if any
    /// segment is missing or the path descends through a non-section leaf.
    ///
    /// `get` returns the value AS-IS: a `.list` stays a `.list`.
    ///
    /// The path is split on every `.`, so a name that itself contains `.`
    /// (a gitconfig subsection like `[branch "feature.x"]`) is unreachable
    /// here; use `getSegments` to address it verbatim.
    pub fn get(self: Section, path: []const u8) ?Value {
        var it = PathIterator{ .rest = path };
        var current = self;
        while (it.next()) |seg| {
            const v = current.findValue(seg) orelse return null;
            if (it.rest.len == 0) return v;
            if (v == .section) {
                current = v.section.*;
                continue;
            }
            return null; // hit a leaf with path still remaining
        }
        return null;
    }

    /// Walk an explicit segment path and return the stored `Value`. Unlike
    /// `get`, segments are matched verbatim with NO splitting, so a name
    /// containing `.` is addressable. Null if any segment is missing or the
    /// path descends through a non-section leaf.
    pub fn getSegments(self: Section, segments: []const []const u8) ?Value {
        var current = self;
        for (segments, 0..) |seg, i| {
            const v = current.findValue(seg) orelse return null;
            if (i + 1 == segments.len) return v;
            if (v == .section) {
                current = v.section.*;
                continue;
            }
            return null;
        }
        return null;
    }

    /// Resolve `path` to a leaf value and return every occurrence as a
    /// freshly-allocated slice of string pointers.
    ///
    /// Returns null when the path resolves to a section or is missing.
    /// For a `.string` leaf, the result is a 1-element slice.
    /// For a `.list` leaf, the result is an N-element slice copying the
    /// element pointers (inner pointers are borrowed from the parse arena).
    ///
    /// Caller owns the outer slice and frees it with `gpa.free(result.?)`.
    /// Inner string slices must not be freed by the caller.
    pub fn getAll(
        self: Section,
        gpa: std.mem.Allocator,
        path: []const u8,
    ) std.mem.Allocator.Error!?[]const []const u8 {
        return expandAll(gpa, self.get(path));
    }

    /// Segment-path counterpart of `getAll`: resolves a name containing `.`
    /// verbatim. Same ownership contract (caller frees the outer slice).
    pub fn getAllSegments(
        self: Section,
        gpa: std.mem.Allocator,
        segments: []const []const u8,
    ) std.mem.Allocator.Error!?[]const []const u8 {
        return expandAll(gpa, self.getSegments(segments));
    }

    /// Expand a resolved leaf into a freshly-allocated slice of value pointers,
    /// or null for a section / unresolved path. Shared by both getAll variants.
    fn expandAll(
        gpa: std.mem.Allocator,
        maybe_v: ?Value,
    ) std.mem.Allocator.Error!?[]const []const u8 {
        const v = maybe_v orelse return null;
        switch (v) {
            .section => return null,
            .string => |s| {
                const out = try gpa.alloc([]const u8, 1);
                out[0] = s;
                return out;
            },
            .list => |elems| {
                const out = try gpa.alloc([]const u8, elems.len);
                @memcpy(out, elems);
                return out;
            },
        }
    }

    /// Look up `path` in the `Spans` map and return the value + span pair.
    /// Returns null if the path does not resolve OR if spans has no entry
    /// for this path (e.g., span tracking was not enabled at parse time).
    pub fn locate(self: Section, spans: *const Spans, path: []const u8) ?LocateResult {
        const v = self.get(path) orelse return null;
        const span = spans.get(path) orelse return null;
        return .{ .value = v, .span = span };
    }

    /// Segment-path counterpart of `locate`. The value is resolved verbatim by
    /// segments (so a dotted name is reachable); the span is keyed by the same
    /// `.`-joined form the parser records, so a scratch `gpa` builds that key.
    /// The key is freed before returning; nothing else is allocated.
    pub fn locateSegments(
        self: Section,
        gpa: std.mem.Allocator,
        spans: *const Spans,
        segments: []const []const u8,
    ) std.mem.Allocator.Error!?LocateResult {
        const v = self.getSegments(segments) orelse return null;
        const key = try std.mem.join(gpa, ".", segments);
        defer gpa.free(key);
        const span = spans.get(key) orelse return null;
        return .{ .value = v, .span = span };
    }
};

/// Splits a dotted path on `.` one segment at a time.
const PathIterator = struct {
    rest: []const u8,

    fn next(self: *PathIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const dot = std.mem.indexOfScalar(u8, self.rest, '.') orelse {
            const seg = self.rest;
            self.rest = "";
            return seg;
        };
        const seg = self.rest[0..dot];
        self.rest = self.rest[dot + 1 ..];
        return seg;
    }
};

// Tests

test "get navigates section.subsection.key" {
    var url_entries = [_]Entry{.{ .key = "url", .value = .{ .string = "git@example.com" } }};
    var origin = Section{ .entries = &url_entries };
    var origin_entries = [_]Entry{.{ .key = "origin", .value = .{ .section = &origin } }};
    var remote = Section{ .entries = &origin_entries };
    var root_entries = [_]Entry{.{ .key = "remote", .value = .{ .section = &remote } }};
    const root = Section{ .entries = &root_entries };

    try testing.expectEqualStrings("git@example.com", root.get("remote.origin.url").?.string);
    try testing.expect(root.get("remote.origin.missing") == null);
    try testing.expect(root.get("nope") == null);
}

test "getAll returns every occurrence for a list value" {
    var values = [_][]const u8{ "refs/a", "refs/b" };
    var entries = [_]Entry{.{ .key = "push", .value = .{ .list = &values } }};
    const sec = Section{ .entries = &entries };
    const all = try sec.getAll(testing.allocator, "push");
    defer testing.allocator.free(all.?);
    try testing.expectEqual(@as(usize, 2), all.?.len);
    try testing.expectEqualStrings("refs/b", all.?[1]);
}

test "getAll on a single string yields one element" {
    var entries = [_]Entry{.{ .key = "name", .value = .{ .string = "x" } }};
    const sec = Section{ .entries = &entries };
    const all = try sec.getAll(testing.allocator, "name");
    defer testing.allocator.free(all.?);
    try testing.expectEqual(@as(usize, 1), all.?.len);
}

test "get returns stored Value as-is for a list" {
    var values = [_][]const u8{ "a", "b", "c" };
    var entries = [_]Entry{.{ .key = "items", .value = .{ .list = &values } }};
    const sec = Section{ .entries = &entries };
    const v = sec.get("items").?;
    try testing.expectEqual(@as(usize, 3), v.list.len);
    try testing.expectEqualStrings("c", v.list[2]);
}

test "get returns null when path descends through a leaf" {
    var entries = [_]Entry{.{ .key = "name", .value = .{ .string = "x" } }};
    const sec = Section{ .entries = &entries };
    try testing.expect(sec.get("name.deeper") == null);
}

test "getAll returns null for a section node" {
    var inner_entries: [0]Entry = .{};
    var inner = Section{ .entries = &inner_entries };
    var entries = [_]Entry{.{ .key = "sub", .value = .{ .section = &inner } }};
    const sec = Section{ .entries = &entries };
    const all = try sec.getAll(testing.allocator, "sub");
    try testing.expect(all == null);
}

test "getAll returns null for a missing path" {
    var entries: [0]Entry = .{};
    const sec = Section{ .entries = &entries };
    const all = try sec.getAll(testing.allocator, "nope");
    try testing.expect(all == null);
}

test "locate returns value and span for a tracked path" {
    var entries = [_]Entry{.{ .key = "url", .value = .{ .string = "https://example.com" } }};
    const sec = Section{ .entries = &entries };

    var spans: Spans = .empty;
    defer spans.deinit(testing.allocator);
    try spans.put(testing.allocator, "url", .{ .start = 0, .end = 20 });

    const result = sec.locate(&spans, "url").?;
    try testing.expectEqualStrings("https://example.com", result.value.string);
    try testing.expectEqual(@as(u64, 0), result.span.start);
    try testing.expectEqual(@as(u64, 20), result.span.end);
}

test "Span is 16 bytes (u64 offsets, no line/col)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Span));
}

test "lineCol derives 1-indexed line/col from a byte offset" {
    const src = "ab\ncde\nf";
    // First byte.
    try testing.expectEqual(LineCol{ .line = 1, .col = 1 }, (Span{ .start = 0, .end = 0 }).lineCol(src));
    // Mid first line.
    try testing.expectEqual(LineCol{ .line = 1, .col = 2 }, (Span{ .start = 1, .end = 2 }).lineCol(src));
    // First byte after a newline.
    try testing.expectEqual(LineCol{ .line = 2, .col = 1 }, (Span{ .start = 3, .end = 4 }).lineCol(src));
    // Mid second line.
    try testing.expectEqual(LineCol{ .line = 2, .col = 3 }, (Span{ .start = 5, .end = 6 }).lineCol(src));
    // Start of third line.
    try testing.expectEqual(LineCol{ .line = 3, .col = 1 }, (Span{ .start = 7, .end = 8 }).lineCol(src));
    // Offset past end clamps to src length.
    try testing.expectEqual(LineCol{ .line = 3, .col = 2 }, (Span{ .start = 100, .end = 100 }).lineCol(src));
}

test "locate returns null when path is missing" {
    var entries: [0]Entry = .{};
    const sec = Section{ .entries = &entries };
    var spans: Spans = .empty;
    defer spans.deinit(testing.allocator);
    try testing.expect(sec.locate(&spans, "nope") == null);
}

test "locate returns null when span is not tracked" {
    var entries = [_]Entry{.{ .key = "url", .value = .{ .string = "x" } }};
    const sec = Section{ .entries = &entries };
    const empty_spans: Spans = .empty;
    try testing.expect(sec.locate(&empty_spans, "url") == null);
}

test "getSegments reaches a subsection name containing a dot" {
    // [branch "feature.x"] merge = ... -- the dotted API cannot address this.
    var merge = [_]Entry{.{ .key = "merge", .value = .{ .string = "refs/heads/main" } }};
    var feature = Section{ .entries = &merge };
    var sub = [_]Entry{.{ .key = "feature.x", .value = .{ .section = &feature } }};
    var branch = Section{ .entries = &sub };
    var root_entries = [_]Entry{.{ .key = "branch", .value = .{ .section = &branch } }};
    const root = Section{ .entries = &root_entries };

    try testing.expectEqualStrings(
        "refs/heads/main",
        root.getSegments(&.{ "branch", "feature.x", "merge" }).?.string,
    );
    // The dotted API splits on the '.', so the same name is unreachable there.
    try testing.expect(root.get("branch.feature.x.merge") == null);
    // Missing verbatim segment yields null.
    try testing.expect(root.getSegments(&.{ "branch", "feature.y", "merge" }) == null);
    // Empty segment list resolves to null, like get("").
    try testing.expect(root.getSegments(&.{}) == null);
}

test "getSegments still works for dot-free segments" {
    var url_entries = [_]Entry{.{ .key = "url", .value = .{ .string = "git@example.com" } }};
    var origin = Section{ .entries = &url_entries };
    var origin_entries = [_]Entry{.{ .key = "origin", .value = .{ .section = &origin } }};
    var remote = Section{ .entries = &origin_entries };
    var root_entries = [_]Entry{.{ .key = "remote", .value = .{ .section = &remote } }};
    const root = Section{ .entries = &root_entries };

    try testing.expectEqualStrings(
        "git@example.com",
        root.getSegments(&.{ "remote", "origin", "url" }).?.string,
    );
    // A leaf with segments still remaining resolves to null.
    try testing.expect(root.getSegments(&.{ "remote", "origin", "url", "deeper" }) == null);
}

test "getAllSegments expands a dotted-name leaf" {
    var values = [_][]const u8{ "a", "b" };
    var push = [_]Entry{.{ .key = "push", .value = .{ .list = &values } }};
    var sub_sec = Section{ .entries = &push };
    var sub = [_]Entry{.{ .key = "sub.domain", .value = .{ .section = &sub_sec } }};
    var remote = Section{ .entries = &sub };
    var root_entries = [_]Entry{.{ .key = "remote", .value = .{ .section = &remote } }};
    const root = Section{ .entries = &root_entries };

    const all = try root.getAllSegments(testing.allocator, &.{ "remote", "sub.domain", "push" });
    defer testing.allocator.free(all.?);
    try testing.expectEqual(@as(usize, 2), all.?.len);
    try testing.expectEqualStrings("b", all.?[1]);
    try testing.expect((try root.getAllSegments(testing.allocator, &.{ "remote", "nope" })) == null);
}

test "locateSegments returns value and span keyed by the dotted join" {
    var merge = [_]Entry{.{ .key = "merge", .value = .{ .string = "refs/heads/main" } }};
    var feature = Section{ .entries = &merge };
    var sub = [_]Entry{.{ .key = "feature.x", .value = .{ .section = &feature } }};
    var branch = Section{ .entries = &sub };
    var root_entries = [_]Entry{.{ .key = "branch", .value = .{ .section = &branch } }};
    const root = Section{ .entries = &root_entries };

    var spans: Spans = .empty;
    defer spans.deinit(testing.allocator);
    try spans.put(testing.allocator, "branch.feature.x.merge", .{ .start = 5, .end = 20 });

    const result = (try root.locateSegments(testing.allocator, &spans, &.{ "branch", "feature.x", "merge" })).?;
    try testing.expectEqualStrings("refs/heads/main", result.value.string);
    try testing.expectEqual(@as(u64, 5), result.span.start);
    // A resolvable value with no tracked span yields null.
    try testing.expect((try root.locateSegments(testing.allocator, &spans, &.{ "branch", "feature.y" })) == null);
}
