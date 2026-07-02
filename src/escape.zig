//! Git-config value scanning, decoding, and encoding.
//!
//! `scanLine` is the single source of truth for gitconfig value semantics: it
//! is shared by the line framer (which only needs to know where a value ends)
//! and the value decoder (which also materializes the decoded bytes), so the
//! buffered parser, the streaming reader, and the tokenizer can never disagree
//! about quote spans, escapes, inline comments, or continuation joins.
//!
//! Git treats a value as a single character stream: a backslash escapes the
//! next char (`\"`, `\\`, `\n`, `\t`, `\b`, or `\<newline>` for continuation);
//! a double quote toggles a quoted span where whitespace and comment chars are
//! literal; an unquoted unescaped `;`/`#` starts an inline comment that runs to
//! end of line; unquoted leading/trailing whitespace is trimmed. Any other
//! backslash escape and any unterminated quote are hard errors, matching
//! `git config`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dialect = @import("dialect.zig").Dialect;

/// Hard errors git raises on a malformed value (`fatal: bad config line`).
pub const ScanError = error{
    /// A backslash escape other than `\" \\ \n \t \b \<newline>`.
    InvalidEscape,
    /// A double-quoted span left open at value end.
    UnterminatedQuote,
};

/// Whether a scanned physical line ends the value or continues onto the next.
pub const LineResult = enum { ended, continues };

/// Scan state carried across a value's continuation lines. `started` gates the
/// leading-whitespace skip (git skips whitespace only before the first value
/// byte); `significant` marks the output length up to the last non-whitespace
/// unquoted byte, so trailing whitespace is dropped while interior whitespace
/// (including tabs) is preserved verbatim.
pub const State = struct {
    in_quote: bool = false,
    started: bool = false,
    significant: usize = 0,
};

fn decodeEscape(c: u8) ?u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'b' => 8,
        '"' => '"',
        '\\' => '\\',
        else => null,
    };
}

/// Append a value-significant byte, advancing the significant cut to include it.
fn emitSig(arena: Allocator, out: ?*std.ArrayList(u8), st: *State, byte: u8) Allocator.Error!void {
    if (out) |o| {
        try o.append(arena, byte);
        st.significant = o.items.len;
    }
    st.started = true;
}

/// Append interior unquoted whitespace verbatim without advancing the
/// significant cut, so a trailing run is trimmed at value end.
fn emitWs(arena: Allocator, out: ?*std.ArrayList(u8), byte: u8) Allocator.Error!void {
    if (out) |o| try o.append(arena, byte);
}

fn emitEscape(arena: Allocator, out: ?*std.ArrayList(u8), st: *State, esc: u8) (ScanError || Allocator.Error)!void {
    if (decodeEscape(esc)) |d| {
        try emitSig(arena, out, st, d);
    } else if (out != null) {
        return error.InvalidEscape;
    } else {
        try emitSig(arena, out, st, esc);
    }
}

/// Scan one physical line of a gitconfig value, advancing `st`. With `out`
/// non-null the decoded bytes are appended (incremental decode across
/// continuations); with `out` null only `st` advances, for line framing.
/// Returns whether the value continues onto the next physical line. The
/// erroring paths fire only while decoding (`out` non-null); framing is
/// infallible, so framing and decode share this scanner without diverging.
pub fn scanLine(arena: Allocator, out: ?*std.ArrayList(u8), line: []const u8, st: *State) (ScanError || Allocator.Error)!LineResult {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (st.in_quote) {
            switch (c) {
                '"' => st.in_quote = false,
                '\\' => {
                    i += 1;
                    if (i >= line.len) return .continues; // escaped newline inside a quote
                    try emitEscape(arena, out, st, line[i]);
                },
                else => try emitSig(arena, out, st, c), // quoted whitespace is significant
            }
            continue;
        }
        if (c == ' ' or c == '\t') {
            if (st.started) try emitWs(arena, out, c); // skip leading, keep interior
            continue;
        }
        if (c == ';' or c == '#') return .ended; // unquoted inline comment
        switch (c) {
            '\\' => {
                i += 1;
                if (i >= line.len) {
                    // A continuation backslash commits any pending unquoted
                    // whitespace as significant: git keeps `a \<nl>` as `a `,
                    // not `a`, because the join makes the space interior.
                    if (out) |o| st.significant = o.items.len;
                    return .continues;
                }
                try emitEscape(arena, out, st, line[i]);
            },
            '"' => st.in_quote = true,
            else => try emitSig(arena, out, st, c),
        }
    }
    if (st.in_quote and out != null) return error.UnterminatedQuote;
    return .ended;
}

/// Framing-only scan: advance `st` over a physical line and report whether the
/// value continues. Infallible because `scanLine` errors only when decoding.
pub fn framingScan(line: []const u8, st: *State) LineResult {
    return scanLine(undefined, null, line, st) catch unreachable;
}

/// Decode a gitconfig value given its first physical line's value region and
/// the raw contents of any continuation lines, returning the arena-owned bytes.
/// Shared by the streaming reader and the public `unescapeGit`.
pub fn decode(arena: Allocator, first: []const u8, conts: []const []const u8) (ScanError || Allocator.Error)![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var st: State = .{};
    var res = try scanLine(arena, &out, first, &st);
    var i: usize = 0;
    while (res == .continues and i < conts.len) : (i += 1) {
        res = try scanLine(arena, &out, conts[i], &st);
    }
    if (res == .continues and st.in_quote) return error.UnterminatedQuote;
    return out.items[0..st.significant];
}

/// Decode a single, continuation-joined gitconfig value into an arena-allocated
/// string. Convenience over `decode` for callers that already hold one value.
pub fn unescapeGit(arena: Allocator, raw: []const u8) (ScanError || Allocator.Error)![]const u8 {
    return decode(arena, raw, &.{});
}

/// Unescape `\\` -> `\` and `\"` -> `"` inside a quoted subsection name. Per
/// git, those are the only recognized escapes; any other backslash sequence is
/// passed through unchanged. Shared by the buffered parser and the streaming
/// reader so a streamed subsection matches a buffered one.
pub fn unescapeSubsection(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    for (raw) |c| if (c == '\\') break else continue else return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            switch (raw[i + 1]) {
                '\\' => {
                    try out.append(arena, '\\');
                    i += 1;
                },
                '"' => {
                    try out.append(arena, '"');
                    i += 1;
                },
                else => try out.append(arena, c),
            }
        } else {
            try out.append(arena, c);
        }
    }
    return out.items;
}

/// Write a gitconfig-encoded value to `w`.
///
/// Emits raw when the value needs no quoting; otherwise wraps in double
/// quotes and encodes backslashes, double quotes, newlines, and tabs as
/// their git escape sequences. Raw emission preserves round-trip stability
/// for plain identifiers; quoted emission preserves leading/trailing
/// whitespace and embedded special characters.
pub fn escapeGit(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (!needsGitQuoting(s)) {
        try w.writeAll(s);
        return;
    }
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            8 => try w.writeAll("\\b"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn needsGitQuoting(s: []const u8) bool {
    if (s.len > 0) {
        const first = s[0];
        if (first == ' ' or first == '\t') return true;
        const last = s[s.len - 1];
        if (last == ' ' or last == '\t') return true;
    }
    for (s) |c| {
        switch (c) {
            // Characters that git treats as inline-comment starters or that
            // require quoting to round-trip through git config correctly.
            '"', '\\', '\n', '#', ';', '\r', 8 => return true,
            else => {},
        }
    }
    return false;
}

/// True when `s` ends in an odd-parity run of backslashes. Under a backslash
/// continuation dialect with no quoting, such a value emits a trailing `\` that
/// the parser reads as a line continuation, splicing the following key's line
/// into this value (and dropping that key).
fn endsWithOddBackslash(s: []const u8) bool {
    var n: usize = 0;
    var i: usize = s.len;
    while (i > 0 and s[i - 1] == '\\') : (i -= 1) n += 1;
    return n % 2 == 1;
}

/// Shared bytes that no INI dialect can carry losslessly in a value:
/// a carriage return is a physical-line terminator to the tokenizer and has no
/// git escape, so it always splits or unbalances the re-parsed value.
fn hasCarriageReturn(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '\r') != null;
}

/// True when a raw git-value literal leaves a double-quote span open. A `\`
/// escapes the next byte (so `\"` is a literal quote that does not toggle the
/// span); an unescaped `"` toggles it. An open span at the end re-parses to
/// `error.UnterminatedQuote`, breaking the whole document.
fn unbalancedGitQuote(s: []const u8) bool {
    var in_quote = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '"' => in_quote = !in_quote,
            else => {},
        }
    }
    return in_quote;
}

/// Structural-break gate for a raw, unescaped literal spliced verbatim by
/// `Document.setLiteral`. Independent of value-level round-trip: it rejects only
/// literals that would break the DOCUMENT structure on re-parse - an odd
/// trailing backslash run that swallows the following line under backslash
/// continuation, or an unbalanced git double-quote that leaves the value's quote
/// span open. A carriage return and an embedded newline are screened separately
/// by the caller. Genuinely-raw-but-safe literals stay allowed.
pub fn structureBreakingLiteral(d: Dialect, s: []const u8) bool {
    if (d.line_continuation == .backslash and endsWithOddBackslash(s)) return true;
    if (d.quoting == .git and unbalancedGitQuote(s)) return true;
    return false;
}

/// True when `s` begins and ends with a double quote (length >= 2). Such a
/// value is stripped of its outer pair by a `strip_value_quotes` dialect on
/// re-parse, so emitting it raw would not round-trip.
pub fn hasSurroundingQuotePair(s: []const u8) bool {
    return s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"';
}

/// Non-git single-line representability: the parser trims leading/trailing
/// space and tab, and (under backslash continuation) an odd trailing backslash
/// run swallows the next key. A `strip_value_quotes` dialect drops a surrounding
/// double-quote pair on re-parse. A git-quoting dialect represents the
/// whitespace and backslash cases via quoting and escaping, so this applies
/// only to `.none` quoting.
fn nonGitLineUnrepresentable(d: Dialect, s: []const u8) bool {
    if (s.len > 0) {
        const f = s[0];
        const l = s[s.len - 1];
        if (f == ' ' or f == '\t' or l == ' ' or l == '\t') return true;
    }
    if (d.line_continuation == .backslash and endsWithOddBackslash(s)) return true;
    if (d.strip_value_quotes and hasSurroundingQuotePair(s)) return true;
    return false;
}

/// Encoder gate for a value emitted on one physical line. The caller has
/// already rejected a carriage return and routed any embedded newline through
/// indent continuation or git escaping, so a git dialect represents every
/// remaining single-line value; a non-quoting dialect rejects trimmed
/// whitespace and a continuation-swallowing trailing backslash.
pub fn unrepresentableSingleLine(d: Dialect, s: []const u8) bool {
    if (d.quoting == .git) return false;
    return nonGitLineUnrepresentable(d, s);
}

/// Full gate for a value spliced verbatim onto an existing line (Document.set).
/// There is no continuation path here, so an embedded newline is unrepresentable
/// under a non-quoting dialect; a carriage return is unrepresentable everywhere.
/// A git dialect's `escapeGit` carries `\n`, whitespace, comment chars, quotes,
/// and backslashes, so only the carriage return is rejected for it.
pub fn unrepresentableSpliced(d: Dialect, s: []const u8) bool {
    if (hasCarriageReturn(s)) return true;
    if (d.quoting == .git) return false;
    if (std.mem.indexOfScalar(u8, s, '\n') != null) return true;
    return nonGitLineUnrepresentable(d, s);
}

const testing = std.testing;

test "unrepresentableSingleLine: non-git rejects edge whitespace, accepts interior" {
    const D = Dialect.strict;
    try testing.expect(unrepresentableSingleLine(D, " lead"));
    try testing.expect(unrepresentableSingleLine(D, "trail "));
    try testing.expect(unrepresentableSingleLine(D, "\tlead"));
    try testing.expect(!unrepresentableSingleLine(D, "a b"));
    try testing.expect(!unrepresentableSingleLine(D, "a # b"));
}

test "unrepresentableSingleLine: git represents everything single-line" {
    const G = Dialect.gitconfig;
    try testing.expect(!unrepresentableSingleLine(G, " lead"));
    try testing.expect(!unrepresentableSingleLine(G, "trail "));
    try testing.expect(!unrepresentableSingleLine(G, "a\\"));
}

test "unrepresentableSingleLine: systemd rejects odd trailing backslash only" {
    const S = Dialect.systemd;
    try testing.expect(unrepresentableSingleLine(S, "a\\"));
    try testing.expect(unrepresentableSingleLine(S, "a\\\\\\"));
    try testing.expect(!unrepresentableSingleLine(S, "a\\\\"));
    try testing.expect(!unrepresentableSingleLine(S, "a\\b"));
}

test "unrepresentableSpliced: carriage return rejected for every dialect" {
    try testing.expect(unrepresentableSpliced(Dialect.strict, "a\rb"));
    try testing.expect(unrepresentableSpliced(Dialect.gitconfig, "a\rb"));
    try testing.expect(unrepresentableSpliced(Dialect.generic, "a\rb"));
}

test "unrepresentableSpliced: non-git rejects newline, git carries it" {
    try testing.expect(unrepresentableSpliced(Dialect.generic, "a\nb"));
    try testing.expect(unrepresentableSpliced(Dialect.strict, "a\nb"));
    try testing.expect(!unrepresentableSpliced(Dialect.gitconfig, "a\nb"));
}

test "passes a plain value through, trimming trailing space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("abc", try unescapeGit(arena.allocator(), "abc  "));
}

test "double quotes preserve inner whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a b", try unescapeGit(arena.allocator(), "\"a b\""));
    try testing.expectEqualStrings("  x  ", try unescapeGit(arena.allocator(), "\"  x  \""));
}

test "decodes git escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a\tb", try unescapeGit(arena.allocator(), "a\\tb"));
    try testing.expectEqualStrings("a\nb", try unescapeGit(arena.allocator(), "a\\nb"));
    try testing.expectEqualStrings("a\"b", try unescapeGit(arena.allocator(), "a\\\"b"));
    try testing.expectEqualStrings("a\\b", try unescapeGit(arena.allocator(), "a\\\\b"));
    try testing.expectEqualStrings("a\x08b", try unescapeGit(arena.allocator(), "a\\bb"));
}

test "empty value stays empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("", try unescapeGit(arena.allocator(), ""));
    try testing.expectEqualStrings("", try unescapeGit(arena.allocator(), "\"\""));
}

// escapeGit tests

test "escapeGit: plain value emits raw" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "hello");
    try testing.expectEqualStrings("hello", w.buffered());
}

test "escapeGit: value with double quote is quoted and escaped" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "say \"hi\"");
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", w.buffered());
}

test "escapeGit: value with backslash is quoted and escaped" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "a\\b");
    try testing.expectEqualStrings("\"a\\\\b\"", w.buffered());
}

test "escapeGit: value with newline is quoted and escaped" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "a\nb");
    try testing.expectEqualStrings("\"a\\nb\"", w.buffered());
}

test "escapeGit: trailing space triggers quoting" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "val ");
    try testing.expectEqualStrings("\"val \"", w.buffered());
}

test "escapeGit: leading space triggers quoting" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, " val");
    try testing.expectEqualStrings("\" val\"", w.buffered());
}

test "escapeGit: embedded space does not trigger quoting" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "a b");
    try testing.expectEqualStrings("a b", w.buffered());
}

test "escapeGit: empty string emits raw" {
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "");
    try testing.expectEqualStrings("", w.buffered());
}

test "escapeGit round-trips through unescapeGit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "simple",
        "with space",
        "trailing ",
        " leading",
        "quote\"here",
        "back\\slash",
        "new\nline",
        "tab\there",
        "",
        // inline-comment chars must be quoted to survive a round-trip
        "a # b",
        "a ; b",
        "value\r",
        "value\x08end",
    };
    for (cases) |original| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try escapeGit(&w, original);
        const encoded = w.buffered();
        const decoded = try unescapeGit(a, encoded);
        try testing.expectEqualStrings(original, decoded);
    }
}

test "decode: inline comment stripped, escape-aware (git: a\\\" ; b -> a\")" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `a\" ; b`: \" is a literal quote that does not open a span; ` ; b` is a comment.
    try testing.expectEqualStrings("a\"", try decode(arena.allocator(), "a\\\" ; b", &.{}));
}

test "decode: comment carries across a continuation join (git: a   b)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a   b", try decode(arena.allocator(), "a \\", &.{"  b ; c"}));
}

test "decode: trailing backslash inside a comment is not a continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `a ; c \` -> comment starts at `;`; value is just `a`, the `\` is comment text.
    try testing.expectEqualStrings("a", try decode(arena.allocator(), "a ; c \\", &.{}));
}

test "decode: invalid escapes are hard errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidEscape, decode(arena.allocator(), "a\\xb", &.{}));
    try testing.expectError(error.InvalidEscape, decode(arena.allocator(), "a\\zb", &.{}));
    try testing.expectError(error.InvalidEscape, decode(arena.allocator(), "a\\;b", &.{}));
}

test "decode: unterminated quote is a hard error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnterminatedQuote, decode(arena.allocator(), "\"abc", &.{}));
}

test "decode: whitespace before a continuation backslash is preserved (git parity)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // git: `a \<nl>` followed by a blank line keeps the trailing space -> "a ".
    try testing.expectEqualStrings("a ", try decode(a, "a \\", &.{""}));
    try testing.expectEqualStrings("a  ", try decode(a, "a  \\", &.{""}));
    try testing.expectEqualStrings("a\t", try decode(a, "a\t\\", &.{""}));
    // Whitespace before a backslash that is followed by content stays interior.
    try testing.expectEqualStrings("a b", try decode(a, "a \\", &.{"b"}));
}

test "unrepresentableSingleLine: strip_value_quotes rejects a surrounding quote pair" {
    const W = Dialect.windows;
    try testing.expect(unrepresentableSingleLine(W, "\"x\""));
    try testing.expect(unrepresentableSingleLine(W, "\"\""));
    try testing.expect(!unrepresentableSingleLine(W, "\"x"));
    try testing.expect(!unrepresentableSingleLine(W, "x\""));
    try testing.expect(!unrepresentableSingleLine(W, "a\"b"));
    // A dialect without quote stripping keeps a quoted pair representable.
    try testing.expect(!unrepresentableSingleLine(Dialect.strict, "\"x\""));
}

test "structureBreakingLiteral: odd trailing backslash under backslash continuation" {
    try testing.expect(structureBreakingLiteral(Dialect.systemd, "a\\"));
    try testing.expect(structureBreakingLiteral(Dialect.systemd, "a\\\\\\"));
    try testing.expect(structureBreakingLiteral(Dialect.gitconfig, "a\\"));
    // Even runs are escaped pairs, not continuations.
    try testing.expect(!structureBreakingLiteral(Dialect.systemd, "a\\\\"));
    // No backslash continuation dialect: a trailing backslash is plain text.
    try testing.expect(!structureBreakingLiteral(Dialect.generic, "a\\"));
    try testing.expect(!structureBreakingLiteral(Dialect.strict, "a\\"));
}

test "structureBreakingLiteral: unbalanced git quote only under git quoting" {
    try testing.expect(structureBreakingLiteral(Dialect.gitconfig, "a\"b"));
    try testing.expect(structureBreakingLiteral(Dialect.gitconfig, "\""));
    // An escaped quote does not open a span.
    try testing.expect(!structureBreakingLiteral(Dialect.gitconfig, "a\\\"b"));
    try testing.expect(!structureBreakingLiteral(Dialect.gitconfig, "a\"b\"c"));
    // A non-git dialect takes quotes verbatim, so they never break structure.
    try testing.expect(!structureBreakingLiteral(Dialect.strict, "a\"b"));
}

test "framingScan: escaped trailing backslash is not a continuation" {
    var st: State = .{};
    try testing.expectEqual(LineResult.ended, framingScan("value\\\\", &st));
    var st2: State = .{};
    try testing.expectEqual(LineResult.continues, framingScan("value\\", &st2));
}

test "escapeGit: hash and semicolon trigger quoting" {
    // needsGitQuoting must fire for # and ; so inline-comment chars in values
    // are preserved after a write/read cycle.
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try escapeGit(&w, "a # b");
    try testing.expectEqualStrings("\"a # b\"", w.buffered());
    var buf2: [32]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try escapeGit(&w2, "a ; b");
    try testing.expectEqualStrings("\"a ; b\"", w2.buffered());
}
