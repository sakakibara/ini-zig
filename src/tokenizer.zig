//! Line-oriented tokenizer for INI source.
//!
//! Classifies each physical line as blank, comment, section_header, key_value,
//! or continuation. Dialect-aware for comment chars and continuation style only;
//! structural interpretation (subsection quoting, escapes, assign-char parsing)
//! belongs to the parser.
//!
//! Span byte offsets are u64, so any in-memory input is addressable. Line and
//! column are not tracked here; derive them on demand with `Span.lineCol`.

const std = @import("std");
const Span = @import("value.zig").Span;
const Dialect = @import("dialect.zig").Dialect;
const escape = @import("escape.zig");

pub const LineKind = enum {
    blank,
    comment,
    section_header,
    key_value,
    continuation,
};

pub const Token = struct {
    kind: LineKind,
    span: Span,
};

/// Continuation state carried across physical lines. The same struct backs the
/// buffered tokenizer and the streaming framer, so both reach identical line
/// verdicts. For gitconfig the carried `git` scan state makes continuation
/// detection quote-, escape-, and comment-aware (a trailing `\` inside a
/// comment is not a continuation; a quoted span may cross a join).
pub const ClassifyState = struct {
    /// Non-git backslash dialects: previous line ended on an odd run of `\`.
    prev_backslash: bool = false,
    /// Indent dialects: currently inside a key_value logical block.
    in_value_block: bool = false,
    /// Indent dialects: leading-space count of the line that opened the block.
    key_indent: usize = 0,
    /// gitconfig: non-null while inside a continued value; holds the scan state
    /// carried to the next physical line.
    git: ?escape.State = null,
};

/// Index of the first assignment char in `line`, or null when none is present.
/// Shared by the buffered parser, the streaming reader, and the document model
/// so all three split key from value at the same byte.
pub fn findAssign(line: []const u8, assign_chars: []const u8) ?usize {
    for (line, 0..) |c, i| {
        if (std.mem.indexOfScalar(u8, assign_chars, c) != null) return i;
    }
    return null;
}

/// Byte offset just past the first assignment char, or null for a bare key.
fn gitValueStart(line: []const u8, assign_chars: []const u8) ?usize {
    const i = findAssign(line, assign_chars) orelse return null;
    return i + 1;
}

/// Classify one physical line under `d`, advancing `st`. Free function so the
/// buffered tokenizer and the streaming framer share one classifier.
pub fn classifyLine(line: []const u8, d: Dialect, st: *ClassifyState) LineKind {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const trimmed = line[i..];

    if (trimmed.len == 0) {
        // Under indent continuation, preserve in_value_block so that a
        // following indented line is still recognised as a continuation.
        // Blank lines between the key and its continuation become empty
        // segments in the joined value; trailing blanks (no continuation
        // follows) are discarded by the parser's pending_blanks flush.
        if (d.line_continuation == .indent and st.in_value_block) {
            return .blank;
        }
        st.* = .{};
        return .blank;
    }

    switch (d.line_continuation) {
        .backslash => {
            if (d.quoting == .git) {
                if (st.git) |*gs| {
                    if (escape.framingScan(line, gs) == .ended) st.git = null;
                    return .continuation;
                }
            } else if (st.prev_backslash) {
                st.prev_backslash = lineEndsWithBackslash(line);
                return .continuation;
            }
        },
        .indent => {
            if (st.in_value_block and i > st.key_indent) return .continuation;
        },
        .none => {},
    }

    if (std.mem.indexOfScalar(u8, d.comment_chars, trimmed[0]) != null) {
        st.* = .{};
        return .comment;
    }

    if (trimmed[0] == '[') {
        st.* = .{};
        // A git inline key trailing the header (`[s] k = v`) whose value runs
        // off the line (trailing `\` or an open quote) seeds the git scanner
        // so the next physical line is classified as a continuation, matching a
        // normal key line. Without it the continuation would be misread as a
        // fresh key, corrupting the value and inventing a phantom key.
        if (d.quoting == .git) seedHeaderInlineGit(trimmed, d, st);
        return .section_header;
    }

    switch (d.line_continuation) {
        .backslash => {
            if (d.quoting == .git) {
                if (gitValueStart(line, d.assign_chars)) |vs| {
                    var gs: escape.State = .{};
                    st.git = if (escape.framingScan(line[vs..], &gs) == .continues) gs else null;
                } else {
                    st.git = null;
                }
            } else {
                st.prev_backslash = lineEndsWithBackslash(line);
            }
        },
        .indent => {
            st.in_value_block = true;
            st.key_indent = i;
        },
        .none => st.prev_backslash = false,
    }
    return .key_value;
}

/// Seed `st.git` from a git inline key's value when that value continues onto
/// the next physical line. `trimmed` is the header line with leading whitespace
/// already removed; the value region is everything past the inline key's first
/// assignment char, scanned with a fresh state. A bare inline key (no assign)
/// or a comment after `]` carries no continuable value, so `st.git` stays null.
fn seedHeaderInlineGit(trimmed: []const u8, d: Dialect, st: *ClassifyState) void {
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return;
    var after = trimmed[close + 1 ..];
    var k: usize = 0;
    while (k < after.len and (after[k] == ' ' or after[k] == '\t')) k += 1;
    after = after[k..];
    if (after.len == 0) return;
    if (std.mem.indexOfScalar(u8, d.comment_chars, after[0]) != null) return;
    const vs = gitValueStart(after, d.assign_chars) orelse return;
    var gs: escape.State = .{};
    if (escape.framingScan(after[vs..], &gs) == .continues) st.git = gs;
}

pub const Tokenizer = struct {
    src: []const u8,
    dialect: Dialect,
    pos: usize,
    state: ClassifyState,

    pub fn init(src: []const u8, dialect: Dialect) Tokenizer {
        return .{
            .src = src,
            .dialect = dialect,
            .pos = 0,
            .state = .{},
        };
    }

    /// Returns the next line token, or null when the source is exhausted.
    pub fn next(self: *Tokenizer) ?Token {
        if (self.pos >= self.src.len) return null;

        const line_start = self.pos;

        var end = self.pos;
        while (end < self.src.len and self.src[end] != '\n' and self.src[end] != '\r') {
            end += 1;
        }
        const content = self.src[line_start..end];

        if (end < self.src.len) {
            if (self.src[end] == '\r') {
                end += 1;
                if (end < self.src.len and self.src[end] == '\n') end += 1;
            } else {
                end += 1;
            }
        }
        self.pos = end;

        const kind = classifyLine(content, self.dialect, &self.state);
        return .{
            .kind = kind,
            .span = .{
                .start = line_start,
                .end = line_start + content.len,
            },
        };
    }

};

/// True when `line` ends with an odd number of backslashes (after stripping
/// trailing spaces/tabs), meaning the final backslash escapes the newline.
/// An even trailing count means paired escaped backslashes, not continuation.
fn lineEndsWithBackslash(line: []const u8) bool {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) end -= 1;
    if (end == 0 or line[end - 1] != '\\') return false;
    var count: usize = 0;
    while (end > 0 and line[end - 1] == '\\') {
        count += 1;
        end -= 1;
    }
    return count % 2 == 1;
}

const testing = std.testing;

// Zig multiline string: the LAST `\\` line contributes empty string (no `\n`).
// Append "\n" explicitly when a trailing blank line is part of the intended input.

test "classifies blank, comment, header, and key=value lines" {
    const src =
        \\# a comment
        \\
        \\[section]
        \\key = value
        \\
    ++ "\n";
    var tz = Tokenizer.init(src, Dialect.generic);
    try testing.expectEqual(LineKind.comment, tz.next().?.kind);
    try testing.expectEqual(LineKind.blank, tz.next().?.kind);
    try testing.expectEqual(LineKind.section_header, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.blank, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "honors dialect comment and assign chars" {
    const src = "; semicolon comment\nkey : value\n";
    var tz = Tokenizer.init(src, Dialect.generic); // generic allows ':' and ';'
    try testing.expectEqual(LineKind.comment, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
}

test "detects backslash continuation under gitconfig" {
    const src = "key = a \\\nb\n";
    var tz = Tokenizer.init(src, Dialect.gitconfig);
    const t0 = tz.next().?;
    try testing.expectEqual(LineKind.key_value, t0.kind);
    try testing.expectEqual(LineKind.continuation, tz.next().?.kind);
}

test "span tracks byte offsets; line/col derived via lineCol" {
    const src = "# comment\nkey = val\n";
    var tz = Tokenizer.init(src, Dialect.strict);
    const t0 = tz.next().?;
    try testing.expectEqual(LineKind.comment, t0.kind);
    try testing.expectEqual(@as(u64, 0), t0.span.start);
    try testing.expectEqual(@as(u64, 9), t0.span.end);
    try testing.expectEqual(@as(u32, 1), t0.span.lineCol(src).line);
    const t1 = tz.next().?;
    try testing.expectEqual(LineKind.key_value, t1.kind);
    try testing.expectEqual(@as(u64, 10), t1.span.start);
    try testing.expectEqual(@as(u32, 2), t1.span.lineCol(src).line);
}

test "handles input with no trailing newline" {
    const src = "key = value";
    var tz = Tokenizer.init(src, Dialect.strict);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "handles CRLF line endings" {
    const src = "# comment\r\nkey = value\r\n";
    var tz = Tokenizer.init(src, Dialect.strict);
    try testing.expectEqual(LineKind.comment, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "handles lone CR line endings" {
    const src = "[sec]\rkey = v\r";
    var tz = Tokenizer.init(src, Dialect.strict);
    try testing.expectEqual(LineKind.section_header, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "chained backslash continuation" {
    const src = "key = a \\\nb \\\nc\n";
    var tz = Tokenizer.init(src, Dialect.gitconfig);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.continuation, tz.next().?.kind);
    try testing.expectEqual(LineKind.continuation, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "indent continuation under generic dialect" {
    const src = "key = value\n    continued\n";
    var tz = Tokenizer.init(src, Dialect.generic);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.continuation, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "no continuation under strict dialect" {
    const src = "key = a\n    indented\n";
    var tz = Tokenizer.init(src, Dialect.strict);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
}

test "windows dialect treats semicolon as comment, ignores #" {
    const src = "; semi\n# hash\n";
    var tz = Tokenizer.init(src, Dialect.windows);
    try testing.expectEqual(LineKind.comment, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
}

test "gitconfig: trailing backslash inside a comment is not a continuation" {
    // `k = a ; c \` -> the `;` opens a comment, so the trailing `\` is comment
    // text and the next line is a fresh (bare) key, not a continuation.
    const src = "[s]\nk = a ; c \\\nb\n";
    var tz = Tokenizer.init(src, Dialect.gitconfig);
    try testing.expectEqual(LineKind.section_header, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "gitconfig: escaped backslash at line end is not a continuation" {
    const src = "[s]\nk = value\\\\\nnext = x\n";
    var tz = Tokenizer.init(src, Dialect.gitconfig);
    try testing.expectEqual(LineKind.section_header, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
}

test "gitconfig: a real continuation line is classified as continuation" {
    const src = "[s]\nk = a \\\n  b ; c\nother = z\n";
    var tz = Tokenizer.init(src, Dialect.gitconfig);
    try testing.expectEqual(LineKind.section_header, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.continuation, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
}

test "P5: blank inside indent value block preserves in_value_block" {
    // Blank line between key and indented continuation: blank is .blank but
    // in_value_block is kept so the indented line is still a continuation.
    const src = "key = v\n\n    cont\n";
    var tz = Tokenizer.init(src, Dialect.generic);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind);
    try testing.expectEqual(LineKind.blank, tz.next().?.kind);
    try testing.expectEqual(LineKind.continuation, tz.next().?.kind);
    try testing.expect(tz.next() == null);
}

test "P5: blank after indent block reset by non-indented next key" {
    // Blank then non-indented line: the blank preserves in_value_block, but
    // the non-indented line is not strictly more indented than the key, so it
    // is classified as key_value (terminates the prior value).
    const src = "key = a\n\nnext = b\n";
    var tz = Tokenizer.init(src, Dialect.generic);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind); // key = a
    try testing.expectEqual(LineKind.blank, tz.next().?.kind);
    try testing.expectEqual(LineKind.key_value, tz.next().?.kind); // next = b
    try testing.expect(tz.next() == null);
}
