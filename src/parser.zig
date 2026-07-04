//! Dialect-driven INI parser. Drives the line tokenizer and folds each line
//! into an arena-allocated section tree (`Value{ .section }` at the root).
//!
//! Every structural decision (comment chars, assignment chars, duplicate-key
//! and duplicate-section resolution, case folding, subsection nesting) is
//! taken from the runtime `Dialect`, so widening from `.strict` to the other
//! presets is a matter of teaching the existing branch points new cases
//! rather than forking the parser.
//!
//! Entry point: `parse(arena, src, options) -> Value`. With `options.errors`
//! set, malformed lines are collected as `Diagnostic`s and skipped; with it
//! null, the first malformed line returns its `Error`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Dialect = @import("dialect.zig").Dialect;
const v = @import("value.zig");
const tok = @import("tokenizer.zig");
const escape = @import("escape.zig");

const Value = v.Value;
const Section = v.Section;
const Entry = v.Entry;
const Span = v.Span;
const Spans = v.Spans;
const Tokenizer = tok.Tokenizer;
const Token = tok.Token;

pub const Error = error{
    /// A key/value line had no assignment character from `dialect.assign_chars`.
    ExpectedAssignment,
    /// A section header was not a well-formed `[name]`.
    MalformedSectionHeader,
    /// A key/value line had nothing before its assignment character.
    EmptyKey,
    /// A key violated the active dialect's name charset (gitconfig requires a
    /// leading letter followed by letters, digits, or hyphens).
    InvalidKey,
    /// A key appeared before any section header in a dialect that forbids it.
    KeyBeforeSection,
    /// A duplicate key under `duplicate_keys = .err`.
    DuplicateKey,
    /// A repeated section header under `duplicate_sections = .err`.
    DuplicateSection,
    /// Subsection nesting exceeded `ParseOptions.max_depth`.
    NestingTooDeep,
    /// A single logical line's raw bytes (the primary physical line plus any
    /// continuation and absorbed-blank lines it joins, including newlines,
    /// comment text, quotes, and escapes) exceeded `ParseOptions.max_line_len`.
    /// A DoS guard against unbounded line accumulation.
    LineTooLong,
    /// A gitconfig value used a backslash escape git does not recognize
    /// (only `\" \\ \n \t \b` and a trailing `\<newline>` are valid).
    InvalidEscape,
    /// A gitconfig value left a double-quoted span open at value end.
    UnterminatedQuote,
} || Allocator.Error;

/// One recovered parse error. Emitted into `ParseOptions.errors` while the
/// parser skips the offending line and continues. Message and suggestion are
/// arena-lifetime; `span` records the offending byte range in the original
/// source. Line/column are derived on demand from `span` and the source.
pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    suggestion: ?[]const u8 = null,

    /// Single-line summary: "error at line:col: message". Line/col are computed
    /// from the span offset against `src` (the original parsed bytes).
    pub fn render(self: Diagnostic, w: *std.Io.Writer, src: []const u8) !void {
        const lc = self.span.lineCol(src);
        try w.print("error at {d}:{d}: {s}", .{ lc.line, lc.col, self.message });
    }

    /// Rustc-style multi-line block: header, source excerpt with caret
    /// underline, optional "did you mean" suggestion. Caller supplies the
    /// original source bytes. ASCII only -- no terminal color escapes.
    pub fn renderRich(self: Diagnostic, w: *std.Io.Writer, src: []const u8) !void {
        const lc = self.span.lineCol(src);
        try w.print("error at {d}:{d}: {s}\n", .{ lc.line, lc.col, self.message });

        // Render the source excerpt only for a real, non-empty span. A
        // locationless diagnostic (e.g. an unknown-field report) carries a
        // zero-width span and shows only the header.
        if (self.span.end > self.span.start) blk: {
            var line_start: usize = 0;
            var lineno: u32 = 1;
            var i: usize = 0;
            while (i < src.len and lineno < lc.line) : (i += 1) {
                if (src[i] == '\n') {
                    lineno += 1;
                    line_start = i + 1;
                }
            }
            if (lineno != lc.line) break :blk;
            var line_end = line_start;
            while (line_end < src.len and src[line_end] != '\n') line_end += 1;

            const line_text = src[line_start..line_end];
            try w.print("  |\n{d:>3} | {s}\n  | ", .{ lc.line, line_text });

            // col is 1-indexed; subtract 1 for zero-based offset into line.
            const col0: usize = if (lc.col > 0) lc.col - 1 else 0;
            const carets: usize = @intCast(self.span.end - self.span.start);
            var c: usize = 0;
            while (c < col0) : (c += 1) try w.writeByte(' ');
            var k: usize = 0;
            while (k < carets) : (k += 1) try w.writeByte('^');
            try w.writeByte('\n');
        }

        if (self.suggestion) |s| {
            try w.print("  = help: did you mean `{s}`?\n", .{s});
        }
    }
};

/// Knobs for `parse` / `parseReader`. `.{}` is the common no-knob case.
pub const ParseOptions = struct {
    /// Selects every lexing and semantic rule. Defaults to `.generic`; this
    /// crate's strict-only parser path is reached by passing `.strict`.
    dialect: Dialect = .generic,
    /// When non-null, each malformed line appends a `Diagnostic` and the
    /// parser recovers (skips the line). The first error's code is still
    /// returned once parsing finishes. When null, the first malformed line
    /// returns its `Error` immediately.
    errors: ?*std.ArrayList(Diagnostic) = null,
    /// When non-null, populated with one span per value, keyed by dotted
    /// key path (e.g. `user.name`).
    spans: ?*Spans = null,
    /// Decode-only knob, honored by later typed-decode layers; ignored by the
    /// dynamic parser.
    ignore_unknown_fields: bool = false,
    /// Subsection nesting ceiling. Exceeding it returns `error.NestingTooDeep`.
    max_depth: usize = 128,
    /// Upper bound on the RAW byte length of one logical line: the primary
    /// physical line plus any continuation (and absorbed blank) lines joined
    /// into it, counting newlines, comment text, quotes, and escape bytes -
    /// not the decoded value length. A logical line whose raw bytes exceed this
    /// returns `error.LineTooLong`. The streaming `EventReader`/`ValueStream`
    /// bound the identical quantity, so a given input yields the same
    /// LineTooLong-or-not decision in buffered and streaming parses. Guards
    /// memory against an adversarial newline-free or continuation-heavy input.
    max_line_len: usize = 16 << 20,
};

pub const ReaderError = Error || std.Io.Reader.LimitedAllocError;

/// Reader-input variant: pulls the whole stream into the arena, then parses.
/// The section tree is only complete once the full input is available.
pub fn parseReader(arena: Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parse(arena, input, options);
}

/// Parse `src` under `options.dialect`, returning the root section value.
pub fn parse(arena: Allocator, src: []const u8, options: ParseOptions) Error!Value {
    // Strip a leading UTF-8 BOM so files saved with BOM parse identically to
    // those without it. The BOM is presentation-layer noise; no token ever
    // contains it.
    const actual = if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src[3..] else src;
    const root = try arena.create(Builder);
    root.* = .{};
    var p = Parser{
        .arena = arena,
        .src = actual,
        .dialect = options.dialect,
        .errors = options.errors,
        .spans = options.spans,
        .max_depth = options.max_depth,
        .max_line_len = options.max_line_len,
        .root = root,
    };
    return p.run();
}

/// Mutable section under construction. The finished tree uses `Section` with
/// a fixed `[]Entry`; during parsing entries grow, so the builder holds an
/// `ArrayList` and is materialized into a `Section` once parsing succeeds.
///
/// `kv_index` and `sec_index` map a stored key/section name to its index in
/// `entries`, giving O(1) duplicate-key and duplicate-section lookup. Keys are
/// stored already folded (lowercased under a case-insensitive dialect), so the
/// maps key on the exact stored bytes. All memory is arena-owned; no deinit.
const Builder = struct {
    entries: std.ArrayList(EntryBuilder) = .empty,
    kv_index: std.StringHashMapUnmanaged(usize) = .empty,
    sec_index: std.StringHashMapUnmanaged(usize) = .empty,
};

const EntryBuilder = struct {
    key: []const u8,
    value: ValueBuilder,
};

/// A leaf accumulates one-or-more raw value strings (one for a scalar, many
/// for an accumulated list); a section points at a child builder.
const ValueBuilder = union(enum) {
    values: std.ArrayList([]const u8),
    section: *Builder,
};

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    dialect: Dialect,
    errors: ?*std.ArrayList(Diagnostic),
    spans: ?*Spans,
    max_depth: usize,
    max_line_len: usize,

    root: *Builder,
    /// Section the next key/value lands in. Null until the first header (and
    /// for global keys, which only non-strict dialects permit).
    current: ?*Builder = null,
    /// Dotted path of `current`, used as the span-map key prefix.
    current_path: []const u8 = "",
    /// Builder and entry index of the last key/value written, for continuation joining.
    prev_builder: ?*Builder = null,
    prev_entry_idx: usize = 0,
    /// Growable accumulator for the value currently being extended by
    /// continuation lines. `cont_builder`/`cont_idx` identify which entry it
    /// backs; a fresh entry starts a new (arena-owned) buffer so the prior
    /// entry's finished slice keeps pointing at its own bytes.
    cont_buf: std.ArrayList(u8) = .empty,
    cont_builder: ?*Builder = null,
    cont_idx: usize = 0,
    /// gitconfig value decode carried across the current value's continuation
    /// lines (shares `cont_buf` as the output). `git_open` records that the most
    /// recent physical line ended on a quote-continuation, so an unterminated
    /// quote at end of input is reported.
    git_state: escape.State = .{},
    git_open: bool = false,
    git_open_span: Span = .{ .start = 0, .end = 0 },
    /// Count of blank lines seen since the last key/value under an indent
    /// continuation dialect. Flushed as empty segments into the value when a
    /// real continuation line arrives; discarded when the value terminates.
    pending_blanks: usize = 0,
    /// Source offset where the current logical line began. Set to a line's start
    /// for a primary line (key/value, header, comment, or a non-absorbed blank);
    /// kept across continuation and absorbed-blank lines so the raw logical-line
    /// length is measured from the primary line. Mirrors the streaming framer's
    /// per-logical-line raw byte count for the `max_line_len` bound.
    logical_start: usize = 0,

    fn run(self: *Parser) Error!Value {
        var tz = Tokenizer.init(self.src, self.dialect);
        var first_err: ?Error = null;

        while (true) {
            const line_start = tz.pos;
            const token = tz.next() orelse break;
            const line_end = tz.pos;
            self.processLine(token, line_start, line_end) catch |err| switch (err) {
                error.OutOfMemory, error.NestingTooDeep, error.LineTooLong => return err,
                else => {
                    if (self.errors == null) return err;
                    if (first_err == null) first_err = err;
                },
            };
        }

        // A value whose last physical line ended on an open quote-continuation
        // (e.g. `k = "a \` at end of input) is unterminated, as git reports.
        if (self.git_open) {
            const e = self.fail(error.UnterminatedQuote, self.git_open_span, "unterminated quoted value");
            if (self.errors == null) return e;
            if (first_err == null) first_err = e;
        }

        if (first_err) |e| return e;
        return Value{ .section = try self.materialize(self.root) };
    }

    fn processLine(self: *Parser, token: Token, line_start: usize, line_end: usize) Error!void {
        // Bound the raw logical-line length. A continuation extends the current
        // logical line; an indent-dialect blank inside an open value block is
        // tentatively absorbed (it may be committed by a following
        // continuation), so neither resets `logical_start`. Every other line
        // begins a fresh logical line. The same quantity (incl. newlines and
        // joined lines) is bounded by the streaming framer, keeping the
        // LineTooLong verdict identical across both paths.
        const absorbed_blank = token.kind == .blank and
            self.dialect.line_continuation == .indent and self.prev_builder != null;
        if (token.kind != .continuation and !absorbed_blank) self.logical_start = line_start;
        if (line_end - self.logical_start > self.max_line_len) return error.LineTooLong;

        switch (token.kind) {
            .blank => {
                // Accumulate blanks only while inside an indent-continuation
                // value block with a preceding key. They are flushed as empty
                // value segments if a real continuation follows, or discarded.
                if (self.dialect.line_continuation == .indent and self.prev_builder != null) {
                    self.pending_blanks += 1;
                }
            },
            .comment => {
                self.pending_blanks = 0;
            },
            .continuation => try self.handleContinuation(token),
            .section_header => {
                self.pending_blanks = 0;
                try self.parseHeader(token);
            },
            .key_value => {
                self.pending_blanks = 0;
                try self.parseKeyValue(token);
            },
        }
    }

    fn parseHeader(self: *Parser, token: Token) Error!void {
        const raw = self.lineContent(token);
        const parts = splitHeader(raw, self.dialect) catch |err| {
            return self.fail(error.MalformedSectionHeader, token.span, headerSyntaxMessage(err));
        };
        const sub: ?[]const u8 = if (parts.subsection) |raw_sub|
            try escape.unescapeSubsection(self.arena, raw_sub)
        else
            null;
        try self.openHeader(parts.name, sub, token.span);
        return self.headerTrailing(parts.rest, token.span);
    }

    /// Handle content after a section header's closing `]`. For git, a
    /// non-comment remainder is parsed as a key (or key=value) inside the
    /// just-opened section, matching `[s] k = v` and `[s]x`. For every other
    /// dialect the remainder is ignored.
    fn headerTrailing(self: *Parser, after: []const u8, span: Span) Error!void {
        if (after.len == 0) return;
        if (self.dialect.quoting != .git) return;
        if (std.mem.indexOfScalar(u8, self.dialect.comment_chars, after[0]) != null) return;
        return self.parseKvContent(after, span);
    }

    /// Join a continuation line onto the last-written key's value. `.indent`
    /// folds with a `\n`; `.backslash` strips the prior line's trailing `\`
    /// and concatenates, keeping leading whitespace of the joined line (git
    /// preserves it as interior whitespace).
    ///
    /// Segments append into a single growable buffer per value slot (builder +
    /// entry + value index), so N continuation lines cost O(N) total rather
    /// than recopying the whole accumulated value per line.
    fn handleContinuation(self: *Parser, token: Token) Error!void {
        if (self.dialect.line_continuation == .none) return;
        const b = self.prev_builder orelse return;
        const eb = &b.entries.items[self.prev_entry_idx];
        if (eb.value != .values) return;
        const vals = &eb.value.values;
        const last_idx = vals.items.len - 1;

        if (self.dialect.quoting == .git) {
            // The git scanner already wrote the primary value into cont_buf; feed
            // this physical line so the decode spans the whole logical value.
            const res = escape.scanLine(self.arena, &self.cont_buf, self.lineContent(token), &self.git_state) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidEscape => return self.fail(error.InvalidEscape, token.span, "invalid backslash escape in value"),
                error.UnterminatedQuote => return self.fail(error.UnterminatedQuote, token.span, "unterminated quoted value"),
            };
            self.git_open = res == .continues and self.git_state.in_quote;
            self.git_open_span = token.span;
            vals.items[last_idx] = self.cont_buf.items[0..self.git_state.significant];
            return;
        }

        if (self.cont_builder != b or self.cont_idx != self.prev_entry_idx) {
            // New continuation target: start a fresh arena-owned buffer seeded
            // with the value so far. The previous buffer's bytes stay valid.
            self.cont_buf = .empty;
            try self.cont_buf.appendSlice(self.arena, vals.items[last_idx]);
            self.cont_builder = b;
            self.cont_idx = self.prev_entry_idx;
        }

        switch (self.dialect.line_continuation) {
            .indent => {
                // Each pending blank becomes an empty line in the joined value,
                // matching Python configparser: "a\n\n    b" -> "a\n\nb".
                // Trailing blanks (no continuation follows) were discarded in
                // processLine before this continuation arrived.
                for (0..self.pending_blanks) |_| {
                    try self.cont_buf.append(self.arena, '\n');
                }
                self.pending_blanks = 0;
                try self.cont_buf.append(self.arena, '\n');
                try self.cont_buf.appendSlice(self.arena, trim(self.lineContent(token)));
            },
            .backslash => {
                if (self.cont_buf.items.len > 0 and self.cont_buf.items[self.cont_buf.items.len - 1] == '\\') {
                    self.cont_buf.items.len -= 1;
                }
                const cont = std.mem.trimEnd(u8, self.lineContent(token), " \t\r");
                try self.cont_buf.appendSlice(self.arena, cont);
            },
            .none => unreachable,
        }
        vals.items[last_idx] = self.cont_buf.items;
    }

    /// Resolve the section a header names and make its leaf `current`,
    /// descending root -> section -> subsection for quoted dialects. The
    /// section segment folds under `case_insensitive_sections`; a quoted
    /// subsection is stored verbatim (case-sensitive).
    fn openHeader(self: *Parser, sec: []const u8, sub: ?[]const u8, span: Span) Error!void {
        const ci = self.dialect.case_insensitive_sections;
        if (sub) |subname| {
            const parent = try self.openSection(self.root, sec, ci, 1, false, span);
            self.current = try self.openSection(parent, subname, false, 2, true, span);
            const sec_stored = if (ci) try toLowerAlloc(self.arena, sec) else sec;
            self.current_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sec_stored, subname });
        } else {
            self.current = try self.openSection(self.root, sec, ci, 1, true, span);
            self.current_path = if (ci) try toLowerAlloc(self.arena, sec) else sec;
        }
        self.prev_builder = null;
    }

    /// Find-or-create `name` as a child section of `parent`. The depth guard
    /// is checked before creating, so an over-deep header never leaves a
    /// partial node in the tree. Only the leaf segment honors
    /// `duplicate_sections`; interior segments always merge, since a path
    /// cannot fork at an interior name. `case_insensitive` governs both match
    /// folding and stored folding.
    fn openSection(
        self: *Parser,
        parent: *Builder,
        name: []const u8,
        case_insensitive: bool,
        depth: usize,
        is_leaf: bool,
        span: Span,
    ) Error!*Builder {
        if (depth > self.max_depth) {
            return self.fail(error.NestingTooDeep, span, "section nesting exceeds max_depth");
        }
        // The index key is the stored form: folded under a case-insensitive
        // section, verbatim for a case-sensitive subsection. Lookup and store
        // must share this form for the dedup to match.
        const stored = if (case_insensitive) try toLowerAlloc(self.arena, name) else name;
        const policy = if (is_leaf) self.dialect.duplicate_sections else .merge;
        switch (policy) {
            .merge => {
                if (parent.sec_index.get(stored)) |idx| return parent.entries.items[idx].value.section;
                return try self.createSectionIn(parent, stored);
            },
            .accumulate => return try self.createSectionIn(parent, stored),
            .err => {
                if (parent.sec_index.get(stored) != null) {
                    return self.fail(error.DuplicateSection, span, "duplicate section header");
                }
                return try self.createSectionIn(parent, stored);
            },
        }
    }

    fn createSectionIn(self: *Parser, parent: *Builder, stored: []const u8) Error!*Builder {
        const b = try self.arena.create(Builder);
        b.* = .{};
        const idx = parent.entries.items.len;
        try parent.entries.append(self.arena, .{ .key = stored, .value = .{ .section = b } });
        try parent.sec_index.put(self.arena, stored, idx);
        return b;
    }

    fn parseKeyValue(self: *Parser, token: Token) Error!void {
        return self.parseKvContent(self.lineContent(token), token.span);
    }

    /// Parse one `key<assign>value` (or bare key) from `content`, applying the
    /// dialect's whitespace, comment, quoting, and charset rules, and insert it
    /// into the current section. Shared by a normal key line and a git inline
    /// key that trails a section header.
    fn parseKvContent(self: *Parser, content: []const u8, span: Span) Error!void {
        const assign = tok.findAssign(content, self.dialect.assign_chars) orelse {
            if (!self.dialect.allow_no_value) {
                return self.fail(error.ExpectedAssignment, span, "expected assignment, found none");
            }
            const bare = trim(content);
            if (bare.len == 0) {
                return self.fail(error.EmptyKey, span, "empty key");
            }
            if (self.current == null and !self.dialect.global_keys) {
                return self.fail(error.KeyBeforeSection, span, "key appears before any section header");
            }
            const stored_bare = try self.storeKey(bare, span);
            return self.putKv(stored_bare, "", span);
        };
        const raw_key = content[0..assign];
        // Emptiness is judged on the trimmed key even when whitespace is kept,
        // so `  = v` is still an empty key.
        if (trim(raw_key).len == 0) {
            return self.fail(error.EmptyKey, span, "empty key before assignment");
        }
        if (self.current == null and !self.dialect.global_keys) {
            return self.fail(error.KeyBeforeSection, span, "key appears before any section header");
        }
        const key_src = if (self.dialect.trim_whitespace) trim(raw_key) else raw_key;
        const stored_key = try self.storeKey(key_src, span);

        if (self.dialect.quoting == .git) {
            return self.putGitKv(stored_key, content[assign + 1 ..], span);
        }
        var val = content[assign + 1 ..];
        if (self.dialect.inline_comments) val = stripInlineComment(val, self.dialect.comment_chars);
        if (self.dialect.trim_whitespace) val = trim(val);
        if (self.dialect.strip_value_quotes and escape.hasSurroundingQuotePair(val)) {
            val = val[1 .. val.len - 1];
        }
        try self.putKv(stored_key, val, span);
    }

    /// Fold `key` per the dialect and enforce its name charset, returning the
    /// stored bytes. A charset violation fails via `fail`, which the run loop
    /// recovers from when an error sink is present.
    fn storeKey(self: *Parser, key: []const u8, span: Span) Error![]const u8 {
        if (self.dialect.quoting == .git and !validGitKey(key)) {
            return self.fail(error.InvalidKey, span, "invalid key charset");
        }
        return if (self.dialect.case_insensitive_keys)
            try toLowerAlloc(self.arena, key)
        else
            key;
    }

    /// Decode a gitconfig value's first physical line via the shared scanner and
    /// store it, binding the continuation slot so later continuation lines feed
    /// the same decoder. The decode is escape-, quote-, and comment-aware, so
    /// the stored bytes match `git config` and the streaming reader.
    fn putGitKv(self: *Parser, key: []const u8, vregion: []const u8, span: Span) Error!void {
        self.cont_buf = .empty;
        self.git_state = .{};
        const res = escape.scanLine(self.arena, &self.cont_buf, vregion, &self.git_state) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEscape => return self.fail(error.InvalidEscape, span, "invalid backslash escape in value"),
            error.UnterminatedQuote => return self.fail(error.UnterminatedQuote, span, "unterminated quoted value"),
        };
        self.git_open = res == .continues and self.git_state.in_quote;
        self.git_open_span = span;
        // The decoded value lives in the arena, not `src`, so recordSpan falls
        // back to the span passed here. Point it at the raw value region in
        // source (first significant char to line content end) so the document
        // model can splice over the value token.
        try self.putKv(key, self.cont_buf.items[0..self.git_state.significant], self.gitValueSpan(vregion));
        // Bind the continuation slot to the entry putKv just wrote so a following
        // continuation line extends this value rather than reseeding.
        self.cont_builder = self.prev_builder;
        self.cont_idx = self.prev_entry_idx;
    }

    /// Source span of a gitconfig value's raw region: first significant byte
    /// (after the whitespace following `=`) through the line's content end. The
    /// document model re-trims this range; spans for uneditable multi-line
    /// values point at the primary physical line.
    fn gitValueSpan(self: *Parser, vregion: []const u8) Span {
        const base = @intFromPtr(self.src.ptr);
        const vbase = @intFromPtr(vregion.ptr) - base;
        var lead: usize = 0;
        while (lead < vregion.len and (vregion[lead] == ' ' or vregion[lead] == '\t')) lead += 1;
        return .{
            .start = vbase + lead,
            .end = vbase + vregion.len,
        };
    }

    /// Insert `key`/`value` into `current` (or `root` for global keys), applying
    /// `duplicate_keys`. `key` arrives already folded under a case-insensitive
    /// dialect, so `kv_index` keys on the exact stored bytes for O(1) dedup.
    fn putKv(self: *Parser, key: []const u8, value: []const u8, span: Span) Error!void {
        const cur = self.current orelse self.root;

        if (cur.kv_index.get(key)) |idx| {
            const eb = &cur.entries.items[idx];
            switch (self.dialect.duplicate_keys) {
                .last_wins => {
                    eb.value.values.clearRetainingCapacity();
                    try eb.value.values.append(self.arena, value);
                    try self.recordSpan(key, value, span);
                },
                .accumulate => {
                    try eb.value.values.append(self.arena, value);
                    try self.recordSpan(key, value, span);
                },
                .first_wins => { self.prev_builder = null; return; },
                .err => return self.fail(error.DuplicateKey, span, "duplicate key in section"),
            }
            // The value slot for this entry changed (cleared or appended); the
            // next continuation line must reseed cont_buf from the new slot.
            self.cont_builder = null;
            self.prev_builder = cur;
            self.prev_entry_idx = idx;
            return;
        }

        var vals: std.ArrayList([]const u8) = .empty;
        try vals.append(self.arena, value);
        const idx = cur.entries.items.len;
        try cur.entries.append(self.arena, .{ .key = key, .value = .{ .values = vals } });
        try cur.kv_index.put(self.arena, key, idx);
        try self.recordSpan(key, value, span);
        self.prev_builder = cur;
        self.prev_entry_idx = idx;
    }

    /// Record `value`'s source byte range under the dotted key path. Offsets
    /// are taken from the pointer into `src`. u64 offsets address any in-memory
    /// input, so there is no size cap.
    fn recordSpan(self: *Parser, key: []const u8, value: []const u8, span: Span) Error!void {
        const sm = self.spans orelse return;
        const base = @intFromPtr(self.src.ptr);
        const vp = @intFromPtr(value.ptr);
        const path = if (self.current_path.len == 0)
            try self.arena.dupe(u8, key)
        else
            try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ self.current_path, key });
        // Synthetic values (e.g. a bare key's empty string) point outside `src`;
        // fall back to the line span rather than do out-of-range arithmetic.
        if (vp < base or vp > base + self.src.len or vp + value.len > base + self.src.len) {
            try sm.put(self.arena, path, span);
            return;
        }
        const start = vp - base;
        try sm.put(self.arena, path, .{ .start = start, .end = start + value.len });
    }

    /// Convert a builder subtree into the immutable `Section` tree. A leaf
    /// with one accumulated value is a `.string`; multiple values become a
    /// `.list`.
    fn materialize(self: *Parser, b: *Builder) Error!*Section {
        const entries = try self.arena.alloc(Entry, b.entries.items.len);
        for (b.entries.items, 0..) |eb, i| {
            const val: Value = switch (eb.value) {
                .section => |sub| .{ .section = try self.materialize(sub) },
                .values => |vals| blk: {
                    // git values are already decoded by the shared scanner at
                    // parse time; other dialects store raw bytes.
                    break :blk if (vals.items.len == 1)
                        Value{ .string = vals.items[0] }
                    else
                        Value{ .list = vals.items };
                },
            };
            entries[i] = .{ .key = eb.key, .value = val };
        }
        const sec = try self.arena.create(Section);
        sec.* = .{ .entries = entries };
        return sec;
    }

    fn lineContent(self: *Parser, token: Token) []const u8 {
        return self.src[@intCast(token.span.start)..@intCast(token.span.end)];
    }

    fn fail(self: *Parser, err: Error, span: Span, message: []const u8) Error {
        if (self.errors) |list| {
            list.append(self.arena, .{ .message = message, .span = span }) catch return error.OutOfMemory;
        }
        return err;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// git key charset: a leading letter then letters, digits, or hyphens.
/// (`git config` rejects `bad config line` otherwise.)
pub fn validGitKey(key: []const u8) bool {
    if (key.len == 0 or !isAlpha(key[0])) return false;
    for (key[1..]) |c| {
        if (!isAlpha(c) and !(c >= '0' and c <= '9') and c != '-') return false;
    }
    return true;
}

/// git section-name charset (the unquoted `[name]` form or the part before a
/// quoted subsection): alphanumerics, `.`, and `-`. Unlike keys, a leading
/// digit, dot, or hyphen is accepted; `.` introduces subsection nesting.
pub fn validGitSectionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isAlpha(c) and !(c >= '0' and c <= '9') and c != '.' and c != '-') return false;
    }
    return true;
}

/// Syntactic parts of one section-header line. `name` and `subsection` alias
/// the input; `subsection` keeps its backslash escapes (the consumer runs
/// `escape.unescapeSubsection` into its own arena).
pub const HeaderParts = struct {
    name: []const u8,
    subsection: ?[]const u8,
    /// Content after the closing `]`, left-trimmed of spaces/tabs. Under git
    /// quoting it may hold an inline key; other dialects ignore it.
    rest: []const u8,
};

pub const HeaderSyntaxError = error{
    MissingClosingBracket,
    EmptySectionName,
    MalformedQuotedSubsection,
    InvalidSectionNameCharset,
};

/// Syntax-only split of a raw section-header line, shared by the buffered
/// parser and the streaming reader so both accept exactly the same headers.
/// Validates bracket framing, the quoted-subsection shape, and the git
/// section-name charset; performs no allocation and no unescaping.
pub fn splitHeader(raw: []const u8, d: Dialect) HeaderSyntaxError!HeaderParts {
    const t = trim(raw);
    if (t.len < 2 or t[0] != '[') return error.MissingClosingBracket;
    // Find the last ']' so that a subsection name containing ']' (e.g.
    // [section "a]b"]) is handled correctly.
    const close = std.mem.lastIndexOfScalar(u8, t, ']') orelse return error.MissingClosingBracket;
    // After ']': for git, a trailing key (or key=value) is an inline entry in
    // this section (`[s] k = v`); a comment char starts a comment. For other
    // dialects trailing content is ignored (configparser drops it). The region
    // is taken from the raw line and only left-trimmed: trailing bytes belong
    // to the inline value, where git's escape and whitespace rules (a
    // continuation `\` vs an invalid `\ `) depend on them.
    const lead = @intFromPtr(t.ptr) - @intFromPtr(raw.ptr);
    const rest = std.mem.trimStart(u8, raw[lead + close + 1 ..], " \t");
    const inner = if (d.trim_section_names) trim(t[1..close]) else t[1..close];
    if (inner.len == 0) return error.EmptySectionName;
    if (d.subsections == .quoted) {
        if (std.mem.indexOfScalar(u8, inner, '"')) |q| {
            const sec = trim(inner[0..q]);
            // The closing quote must sit strictly after the opening one, so a
            // lone quote (`[x"]`, where q is the last byte) is malformed rather
            // than a start>end slice in `inner[q + 1 .. inner.len - 1]`.
            if (sec.len == 0 or inner.len - 1 <= q or inner[inner.len - 1] != '"') {
                return error.MalformedQuotedSubsection;
            }
            if (d.quoting == .git and !validGitSectionName(sec)) {
                return error.InvalidSectionNameCharset;
            }
            return .{ .name = sec, .subsection = inner[q + 1 .. inner.len - 1], .rest = rest };
        }
    }
    if (d.quoting == .git and !validGitSectionName(inner)) {
        return error.InvalidSectionNameCharset;
    }
    return .{ .name = inner, .subsection = null, .rest = rest };
}

/// Diagnostic message for each header syntax error; shared by both consumers
/// so buffered and streaming parses report identical text.
pub fn headerSyntaxMessage(err: HeaderSyntaxError) []const u8 {
    return switch (err) {
        error.MissingClosingBracket => "section header missing closing ']'",
        error.EmptySectionName => "empty section name",
        error.MalformedQuotedSubsection => "malformed quoted subsection",
        error.InvalidSectionNameCharset => "invalid section name charset",
    };
}

/// Strip a trailing inline comment from a non-git value: the first comment
/// char that is preceded by whitespace begins the comment. Requiring a leading
/// space keeps a comment char that is part of the value (e.g. `a#b`) intact.
pub fn stripInlineComment(value: []const u8, comment_chars: []const u8) []const u8 {
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        if (std.mem.indexOfScalar(u8, comment_chars, value[i]) != null and
            (value[i - 1] == ' ' or value[i - 1] == '\t'))
        {
            return value[0..i];
        }
    }
    return value;
}

/// Return a lowercase copy of `s` allocated in `arena`, or `s` unchanged when
/// it is already all-lowercase (zero-copy fast path).
fn toLowerAlloc(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    for (s) |c| {
        if (c >= 'A' and c <= 'Z') {
            const buf = try arena.alloc(u8, s.len);
            for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
            return buf;
        }
    }
    return s;
}

const testing = std.testing;

test "parses sections and key=value into a tree" {
    const src =
        \\[user]
        \\name = Ada
        \\[core]
        \\bare = true
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("Ada", root.get("user.name").?.string);
    try testing.expectEqualStrings("true", root.get("core.bare").?.string);
}

test "strict: duplicate key is last-wins" {
    const src = "[s]\nk = 1\nk = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("2", root.get("s.k").?.string);
}

test "strict: malformed line without errors sink fails" {
    const src = "[s]\nnot a kv line without assign\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ExpectedAssignment, parse(arena.allocator(), src, .{ .dialect = Dialect.strict }));
}

test "strict: duplicate section merges" {
    const src = "[s]\na = 1\n[s]\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("1", root.get("s.a").?.string);
    try testing.expectEqualStrings("2", root.get("s.b").?.string);
}

test "strict: key before section header fails" {
    const src = "k = v\n[s]\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.KeyBeforeSection, parse(arena.allocator(), src, .{ .dialect = Dialect.strict }));
}

test "strict: errors sink collects diagnostics and recovers" {
    const src = "[s]\nbad line one\nbad line two\nk = ok\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(Diagnostic) = .empty;
    try testing.expectError(error.ExpectedAssignment, parse(arena.allocator(), src, .{
        .dialect = Dialect.strict,
        .errors = &errors,
    }));
    try testing.expectEqual(@as(usize, 2), errors.items.len);
}

test "strict: spans map records value spans" {
    const src = "[user]\nname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var spans: Spans = .empty;
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.strict, .spans = &spans });
    const located = root.section.locate(&spans, "user.name").?;
    try testing.expectEqualStrings("Ada", located.value.string);
    try testing.expectEqual(@as(u64, 14), located.span.start);
    try testing.expectEqual(@as(u64, 17), located.span.end);
    try testing.expectEqual(@as(u32, 2), located.span.lineCol(src).line);
    try testing.expectEqual(@as(u32, 8), located.span.lineCol(src).col);
}

test "strict: empty value is an empty string" {
    const src = "[s]\nk =\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("", root.get("s.k").?.string);
}

test "parseReader reads then parses" {
    const src = "[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed(src);
    const root = try parseReader(arena.allocator(), &reader, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("v", root.get("s.k").?.string);
}

test "generic: ':' assignment and indent continuation" {
    const src =
        \\[s]
        \\key : line one
        \\    line two
        \\other = x
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = @import("dialect.zig").Dialect.generic });
    try testing.expectEqualStrings("line one\nline two", root.get("s.key").?.string);
    try testing.expectEqualStrings("x", root.get("s.other").?.string);
}

test "generic: global keys before any section" {
    const src = "topkey = v\n[s]\nk = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = @import("dialect.zig").Dialect.generic });
    try testing.expectEqualStrings("v", root.get("topkey").?.string);
}

test "generic: keys are case-folded" {
    const src = "[s]\nKey = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = @import("dialect.zig").Dialect.generic });
    try testing.expectEqualStrings("v", root.get("s.key").?.string);
}

test "generic: '=' assign splits first; ':' stays in value" {
    const src = "[s]\nkey = val:ue\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = @import("dialect.zig").Dialect.generic });
    try testing.expectEqualStrings("val:ue", root.get("s.key").?.string);
}

test "generic: ':' assign splits first; '=' stays in value" {
    const src = "[s]\nkey : val=ue\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = @import("dialect.zig").Dialect.generic });
    try testing.expectEqualStrings("val=ue", root.get("s.key").?.string);
}

test "gitconfig: quoted subsection becomes a nested path" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[remote \"origin\"]\n\turl = git@example.com\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectEqualStrings("git@example.com", root.get("remote.origin.url").?.string);
}

test "gitconfig: repeated key accumulates into a list" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    const all = root.get("remote.o.push").?.list;
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("b", all[1]);
}

test "gitconfig: bare key stores empty string (git raw storage); backslash continuation; quoted value" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[core]\n\tbare\n\tx = \"a b\"\n\ty = one \\\n two\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectEqualStrings("", root.get("core.bare").?.string);
    try std.testing.expectEqualStrings("a b", root.get("core.x").?.string);
    try std.testing.expectEqualStrings("one  two", root.get("core.y").?.string);
}

test "gitconfig P1: backslash-quote outside quotes does not open a span" {
    // git: `a\" ; b` -> the \" is a literal quote; ` ; b` is an inline comment.
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[s]\n\tk = a\\\" ; b\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("a\"", root.get("s.k").?.string);
}

test "gitconfig P2: inline comment on a continuation line is stripped" {
    // git: `a \<nl>  b ; c` -> `a   b` (joins, then strips the ` ; c` comment).
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[s]\n\tk = a \\\n  b ; c\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("a   b", root.get("s.k").?.string);
}

test "gitconfig P3: trailing backslash inside a comment is not a continuation" {
    // git: `a ; c \<nl>b` -> value `a`, plus a separate bare key `b`.
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[s]\n\tk = a ; c \\\nb\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("a", root.get("s.k").?.string);
    try testing.expectEqualStrings("", root.get("s.b").?.string);
}

test "gitconfig P4: invalid escapes are rejected like git" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "[s]\n\tk = a\\xb\n", "[s]\n\tk = a\\zb\n", "[s]\n\tk = a\\;b\n" }) |src| {
        try testing.expectError(error.InvalidEscape, parse(arena.allocator(), src, .{ .dialect = G }));
    }
}

test "gitconfig: subsection is case-sensitive, section/key are not" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[Remote \"Origin\"]\n\tURL = u\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectEqualStrings("u", root.get("remote.Origin.url").?.string);
    try std.testing.expect(root.get("remote.origin.url") == null);
}

test "gitconfig: repeated quoted section merges" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[remote \"o\"]\n\ta = 1\n[remote \"o\"]\n\tb = 2\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectEqualStrings("1", root.get("remote.o.a").?.string);
    try std.testing.expectEqualStrings("2", root.get("remote.o.b").?.string);
}

test "gitconfig: an unmatched quote in a section header is a clean error, not a crash" {
    // A lone opening quote (the quote is the last byte of the inner section
    // text) once sliced `inner[q + 1 .. inner.len - 1]` with start>end, an OOB
    // panic. Every unmatched-quote shape must now fail as MalformedSectionHeader.
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ "[x\"]", "[x\"]\n", "[\"]", "[a\"]", "[\"x]", "[ab\"]\n" }) |src| {
        try std.testing.expectError(
            error.MalformedSectionHeader,
            parse(arena.allocator(), src, .{ .dialect = G }),
        );
    }
}

test "gitconfig: a balanced quoted subsection still parses (empty and non-empty)" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const empty = try parse(arena.allocator(), "[a \"\"]\nk = v\n", .{ .dialect = G });
    try std.testing.expectEqualStrings("v", empty.get("a..k").?.string);
    const named = try parse(arena.allocator(), "[remote \"origin\"]\n\turl = u\n", .{ .dialect = G });
    try std.testing.expectEqualStrings("u", named.get("remote.origin.url").?.string);
}

test "gitconfig: inline key after header folds a backslash continuation (git parity)" {
    // git: `[core] x = a \<nl><tab>b` -> one key `core.x = "a \tb"`, NOT a
    // truncated `a ` plus a phantom `core.b`. Verified with `git config --list`.
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "[core] x = a \\\n\tb\n", .{ .dialect = G });
    try testing.expectEqualStrings("a \tb", root.get("core.x").?.string);
    try testing.expect(root.get("core.b") == null); // no phantom key
}

test "gitconfig: inline key continuation joins like a normal key (git parity)" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // git: `[s] x = a \<nl>b` -> `s.x = "a b"`.
    const r1 = try parse(arena.allocator(), "[s] x = a \\\nb\n", .{ .dialect = G });
    try testing.expectEqualStrings("a b", r1.get("s.x").?.string);
    // git: chained continuation `[core] x = a \<nl> b \<nl> c` -> `a  b  c`.
    const r2 = try parse(arena.allocator(), "[core] x = a \\\n b \\\n c\n", .{ .dialect = G });
    try testing.expectEqualStrings("a  b  c", r2.get("core.x").?.string);
}

test "gitconfig: inline key with an open quote or invalid escape errors like git" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // git: `[core] a-b = "aa\<nl>cc` -> `bad config line 2` (quote never closes).
    try testing.expectError(error.UnterminatedQuote, parse(arena.allocator(), "[core] a-b = \"aa\\\ncc\n", .{ .dialect = G }));
    // git: `[core] x =\ <nl>more` -> `bad config line 1` (`\ ` is an invalid escape).
    try testing.expectError(error.InvalidEscape, parse(arena.allocator(), "[core] x =\\ \nmore\n", .{ .dialect = G }));
    // git: `[core] foo \<nl>bar` -> `bad config line 1` (bare key cannot continue).
    try testing.expectError(error.InvalidKey, parse(arena.allocator(), "[core] foo \\\nbar\n", .{ .dialect = G }));
}

test "gitconfig: single-line inline keys are unaffected (git parity)" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a", (try parse(arena.allocator(), "[core] x = a\n", .{ .dialect = G })).get("core.x").?.string);
    try testing.expectEqualStrings("a b", (try parse(arena.allocator(), "[core] x = \"a b\" ; c\n", .{ .dialect = G })).get("core.x").?.string);
    try testing.expectEqualStrings("", (try parse(arena.allocator(), "[core] autocrlf\n", .{ .dialect = G })).get("core.autocrlf").?.string);
    try testing.expectEqualStrings("u", (try parse(arena.allocator(), "[remote \"o\"] url = u\n", .{ .dialect = G })).get("remote.o.url").?.string);
}

test "generic: indented line after section header does not corrupt prior section value" {
    // prev_builder is reset when a section opens; a continuation cannot join
    // across a section boundary into the previous section's last key.
    const src =
        \\[a]
        \\key = value
        \\[b]
        \\    inner = x
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{
        .dialect = @import("dialect.zig").Dialect.generic,
    });
    try testing.expectEqualStrings("value", root.get("a.key").?.string);
    try testing.expectEqualStrings("x", root.get("b.inner").?.string);
}

test "systemd: repeated key accumulates, no subsections" {
    const S = @import("dialect.zig").Dialect.systemd;
    const src = "[Service]\nEnvironment=A=1\nEnvironment=B=2\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = S });
    const all = root.get("Service.Environment").?.list;
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("B=2", all[1]);
}

test "regression: repeated backslash-continued key under accumulate keeps values independent" {
    // Each occurrence of k has its own continuation; cont_buf must reseed per
    // value slot so list[1] is "bseg2", not "aseg1seg2" (the pre-fix bug).
    const S = @import("dialect.zig").Dialect.systemd;
    const src = "[s]\nk = a\\\nseg1\nk = b\\\nseg2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = S });
    const all = root.get("s.k").?.list;
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("aseg1", all[0]);
    try testing.expectEqualStrings("bseg2", all[1]);
}

test "regression: repeated indent-continued key under last_wins keeps only second value" {
    // Under last_wins the second occurrence replaces the first entirely; its
    // continuation must not bleed the first occurrence's cont_buf.
    const G = @import("dialect.zig").Dialect.generic;
    const src = "[s]\nk = a\n seg1\nk = b\n seg2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("b\nseg2", root.get("s.k").?.string);
}

test "windows: last-wins, ;-only comments, case-insensitive section" {
    const W = @import("dialect.zig").Dialect.windows;
    // ';' is a comment in windows; parse succeeds and last k wins
    const src = "[Sec]\n; a comment\nk=1\nk=2\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = W });
    try std.testing.expectEqualStrings("2", root.get("sec.k").?.string);
}

test "windows: section and key names are matched case-insensitively" {
    const W = @import("dialect.zig").Dialect.windows;
    const src = "[Settings]\nTimeOut = 10\n[SETTINGS]\nTIMEOUT = 20\nUserName = alice\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = W });
    // Both headers merge into one section, and the repeated key is last-wins
    // across spellings, matching GetPrivateProfileString name folding.
    try std.testing.expectEqualStrings("20", root.get("settings.timeout").?.string);
    try std.testing.expectEqualStrings("alice", root.get("settings.username").?.string);
    // The stored form is the folded one; an unfolded path does not resolve.
    try std.testing.expect(root.get("settings.TIMEOUT") == null);
}

test "windows: hash is not a comment char, line without assign returns ExpectedAssignment" {
    const W = @import("dialect.zig").Dialect.windows;
    // '#' is not in windows comment_chars (only ';' is), so a bare '# ...' line
    // has no '=' and fails as a malformed kv line.
    const src = "[Sec]\n# not a comment in windows\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ExpectedAssignment, parse(arena.allocator(), src, .{ .dialect = W }));
}

test "multi-error sink collects every malformed line in one pass" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var errs: std.ArrayList(Diagnostic) = .empty;
    const src = "[s]\nbadline1\nk = ok\nbadline2\n";
    try testing.expectError(error.ExpectedAssignment, parse(arena.allocator(), src, .{
        .dialect = @import("dialect.zig").Dialect.strict,
        .errors = &errs,
    }));
    try testing.expectEqual(@as(usize, 2), errs.items.len);
}

test "renderRich renders a caret under the offending span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    const src = "[s]\nbadline1\n";
    const diag = Diagnostic{
        .message = "expected assignment",
        .span = .{ .start = 4, .end = 12 },
    };
    try diag.renderRich(&aw.writer, src);
    try testing.expect(std.mem.indexOfScalar(u8, aw.written(), '^') != null);
}

test "levenshtein closest: naem matches name" {
    const lev = @import("levenshtein.zig");
    try testing.expectEqualStrings("name", lev.closest(&.{ "name", "email" }, "naem").?);
}

/// Allocator that tallies total bytes requested from a backing allocator.
/// Wrapping a parse arena's backing allocator turns peak memory into a
/// deterministic number, so an O(N^2) continuation join is caught by a linear
/// allocation bound instead of a flaky wall-clock measurement.
const CountingAllocator = struct {
    backing: Allocator,
    total: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.total += len;
        return self.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > m.len) self.total += new_len - m.len;
        return self.backing.rawResize(m, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > m.len) self.total += new_len - m.len;
        return self.backing.rawRemap(m, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(m, a, ra);
    }
};

test "M1: continuation join allocates O(N), not O(N^2)" {
    const cases = [_]struct { d: Dialect, prefix: []const u8, cont: []const u8, last: []const u8 }{
        // Indent folds segments with '\n'; backslash concatenates with none.
        .{ .d = Dialect.generic, .prefix = "[s]\nk = v\n", .cont = " seg\n", .last = " seg\n" },
        .{ .d = Dialect.systemd, .prefix = "[s]\nk = v\\\n", .cont = "seg\\\n", .last = "seg\n" },
    };
    const n: usize = 20_000;

    for (cases) |c| {
        var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer src_arena.deinit();
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(src_arena.allocator(), c.prefix);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try src.appendSlice(src_arena.allocator(), if (i == n - 1) c.last else c.cont);
        }

        var counting = CountingAllocator{ .backing = testing.allocator };
        var arena = std.heap.ArenaAllocator.init(counting.allocator());
        defer arena.deinit();
        const root = try parse(arena.allocator(), src.items, .{ .dialect = c.d });

        const got = root.get("s.k").?.string;
        const want_segments = std.mem.count(u8, got, "seg");
        try testing.expectEqual(n, want_segments);

        // A quadratic join copies the whole accumulated value per line, so its
        // total allocation is ~N^2 segment bytes; a linear join stays a small
        // multiple of the input. 200x input is far below the quadratic floor.
        const bound = 200 * src.items.len;
        if (counting.total >= bound) {
            std.debug.print("M1 alloc {d} >= bound {d} (input {d})\n", .{ counting.total, bound, src.items.len });
            return error.QuadraticAllocation;
        }
    }
}

test "M2: duplicate-key detection is sub-quadratic in time" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(src_arena.allocator(), "[s]\n");
    // n=100_000: a linear-scan dedup does n*(n+1)/2 ~= 5e9 comparisons, which
    // exceeds 2000ms even on fast hardware. The hash index stays well under
    // 100ms. A counting allocator cannot distinguish the two approaches because
    // linear-scan comparisons don't allocate, so timing is the only knob here.
    const n: usize = 100_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try src.print(src_arena.allocator(), "k{d}=v{d}\n", .{ i, i });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const t0 = std.Io.Clock.Timestamp.now(testing.io, .awake);
    const root = try parse(arena.allocator(), src.items, .{ .dialect = Dialect.strict });
    const elapsed_ms: u64 = @intCast(@divFloor(@max(t0.untilNow(testing.io).raw.toNanoseconds(), 0), std.time.ns_per_ms));

    try testing.expectEqual(n, root.get("s").?.section.entries.len);
    try testing.expectEqualStrings("v0", root.get("s.k0").?.string);
    try testing.expectEqualStrings("v99999", root.get("s.k99999").?.string);

    if (elapsed_ms > 2000) {
        std.debug.print("M2 dedup took {d} ms\n", .{elapsed_ms});
        return error.QuadraticTime;
    }
}

test "M3: duplicate-section detection is sub-quadratic in time" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    // n=100_000: same reasoning as M2 - section lookup is hash-indexed so O(N)
    // total, but a linear scan would be O(N^2) comparisons (~5e9 at n=1e5),
    // well over 2000ms. Timing is the only viable bound here (section lookups
    // don't allocate per-compare).
    const n: usize = 100_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try src.print(src_arena.allocator(), "[s{d}]\nk=v\n", .{i});
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const t0 = std.Io.Clock.Timestamp.now(testing.io, .awake);
    const root = try parse(arena.allocator(), src.items, .{ .dialect = Dialect.strict });
    const elapsed_ms: u64 = @intCast(@divFloor(@max(t0.untilNow(testing.io).raw.toNanoseconds(), 0), std.time.ns_per_ms));

    try testing.expectEqual(n, root.section.entries.len);
    try testing.expectEqualStrings("v", root.get("s0.k").?.string);
    try testing.expectEqualStrings("v", root.get("s99999.k").?.string);

    if (elapsed_ms > 2000) {
        std.debug.print("M3 dedup took {d} ms\n", .{elapsed_ms});
        return error.QuadraticTime;
    }
}

test "P5a: blank line within indent continuation is kept as empty line in value" {
    const src = "[s]\nkey = a\n\n    b\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("a\n\nb", root.get("s.key").?.string);
}

test "P5b: blank line then non-indented terminates continuation" {
    const src = "[s]\nkey = a\n\nb = x\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("a", root.get("s.key").?.string);
    try testing.expectEqualStrings("x", root.get("s.b").?.string);
}

test "P5c: trailing blank lines after continuation are stripped from value" {
    const src = "[s]\nkey = a\n\n    b\n\n\n[t]\nother = x\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("a\n\nb", root.get("s.key").?.string);
    try testing.expectEqualStrings("x", root.get("t.other").?.string);
}

test "P5d: multiple blank lines between continuation segments are all preserved" {
    const src = "[s]\nkey = a\n\n\n    b\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("a\n\n\nb", root.get("s.key").?.string);
}

test "P6: section header with trailing semicolon comment is valid" {
    const src = "[s] ; comment\nk = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("1", root.get("s.k").?.string);
}

test "P6: section header with trailing hash comment is valid" {
    const src = "[s] # comment\nk = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("1", root.get("s.k").?.string);
}

test "P6: generic ignores junk after closing bracket (configparser parity)" {
    // configparser: `[s]extra` -> section `s`; trailing junk after `]` is dropped.
    const src = "[s]extra\nk = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("1", root.get("s.k").?.string);
}

test "P6: gitconfig subsection header with trailing comment is valid" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"] # note\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("u", root.get("remote.o.url").?.string);
}

test "DOC6: UTF-8 BOM is stripped before parsing" {
    const src = "\xEF\xBB\xBF[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("v", root.get("s.k").?.string);
}

test "P8: generic preserves section-name whitespace (configparser parity)" {
    // Python configparser stores [ s ] as section ' s ' (with spaces), so
    // `[ s ]` and `[s]` are distinct sections. ini-zig's generic dialect matches.
    const src = "[ s ]\na = 1\n[s]\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("1", root.get(" s .a").?.string);
    try testing.expectEqualStrings("2", root.get("s.b").?.string);
    try testing.expect(root.get("s.a") == null);
}

test "P7: gitconfig rejects keys/sections outside git's charset" {
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Keys: underscore, leading digit, dot, and embedded space are all invalid.
    inline for (.{
        "[s]\n\tfoo_bar = 1\n",
        "[s]\n\t1abc = 1\n",
        "[s]\n\ta.b = 1\n",
        "[s]\n\ta b = 1\n",
    }) |src| {
        try testing.expectError(error.InvalidKey, parse(arena.allocator(), src, .{ .dialect = G }));
    }
    // Section names: underscore and embedded space are invalid.
    inline for (.{ "[a_b]\n\tk = 1\n", "[a b]\n\tk = 1\n" }) |src| {
        try testing.expectError(error.MalformedSectionHeader, parse(arena.allocator(), src, .{ .dialect = G }));
    }
}

test "P7: gitconfig accepts git's permissive section charset and hyphen keys" {
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // git accepts digit-first sections and a hyphen in keys (verified against git).
    const root = try parse(arena.allocator(), "[1abc]\n\tfoo-bar = 1\n", .{ .dialect = G });
    try testing.expectEqualStrings("1", root.get("1abc.foo-bar").?.string);
}

test "P7: non-git dialects keep permissive key/section acceptance" {
    // generic still accepts underscores, dots, and leading digits in names.
    const src = "[a_b]\nfoo_bar = 1\n1key = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("1", root.get("a_b.foo_bar").?.string);
    try testing.expectEqualStrings("2", root.get("a_b.1key").?.string);
}

test "decision4: gitconfig parses an inline key after a section header (git parity)" {
    const G = Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // git: `[s]x` -> bare key x; `[section] key = value` -> section.key=value.
    const r1 = try parse(arena.allocator(), "[s]x\n", .{ .dialect = G });
    try testing.expectEqualStrings("", r1.get("s.x").?.string);
    const r2 = try parse(arena.allocator(), "[section] key = value\n", .{ .dialect = G });
    try testing.expectEqualStrings("value", r2.get("section.key").?.string);
    const r3 = try parse(arena.allocator(), "[section]; cmt\nk = 1\n", .{ .dialect = G });
    try testing.expectEqualStrings("1", r3.get("section.k").?.string);
    // An inline key that violates the key charset is rejected, as git does.
    try testing.expectError(error.InvalidKey, parse(arena.allocator(), "[section] 1bad\n", .{ .dialect = G }));
}

test "B1: trim_whitespace=false stores key and value verbatim" {
    var d = Dialect.strict;
    d.trim_whitespace = false;
    const src = "[s]\n  key  =  val  \n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = d });
    try testing.expectEqualStrings("  val  ", root.get("s.  key  ").?.string);
}

test "B1: inline_comments flag drives stripping for a non-git dialect" {
    var d = Dialect.strict;
    d.inline_comments = true;
    const src = "[s]\nk = val ; remark\nj = a#b\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = d });
    // ` ; remark` is stripped (comment char preceded by whitespace); `a#b` is
    // kept intact (no preceding whitespace).
    try testing.expectEqualStrings("val", root.get("s.k").?.string);
    try testing.expectEqualStrings("a#b", root.get("s.j").?.string);

    // The same dialect with the flag off keeps the inline comment verbatim.
    const root2 = try parse(arena.allocator(), "[s]\nk = val ; remark\n", .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("val ; remark", root2.get("s.k").?.string);
}

test "B6: windows strips one surrounding double-quote pair" {
    const W = Dialect.windows;
    const src = "[s]\na=\"x\"\nb=x\nc=\"a\"b\"\nd=\"unbalanced\ne=\"\"\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = W });
    try testing.expectEqualStrings("x", root.get("s.a").?.string);
    try testing.expectEqualStrings("x", root.get("s.b").?.string);
    // Only the balanced outer pair is removed: `"a"b"` -> `a"b`.
    try testing.expectEqualStrings("a\"b", root.get("s.c").?.string);
    // A lone leading quote is not a balanced pair; kept verbatim.
    try testing.expectEqualStrings("\"unbalanced", root.get("s.d").?.string);
    try testing.expectEqualStrings("", root.get("s.e").?.string);
}

test "decision6: gitconfig keeps whitespace before a continuation backslash (git parity)" {
    const G = Dialect.gitconfig;
    // git: `k = a \<nl><blank>` -> `a ` (trailing space before `\` preserved).
    const src = "[s]\n\tk = a \\\n\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("a ", root.get("s.k").?.string);
}

test "M4: a logical line over max_line_len fails fast with LineTooLong" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(src_arena.allocator(), "[s]\nk = v\n");
    var i: usize = 0;
    while (i < 1000) : (i += 1) try src.appendSlice(src_arena.allocator(), " seg\n");
    try testing.expect(src.items.len > 2000);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.LineTooLong, parse(arena.allocator(), src.items, .{
        .dialect = @import("dialect.zig").Dialect.generic,
        .max_line_len = 1024,
    }));
}
