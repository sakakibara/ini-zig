//! Reader-backed, line-oriented INI event reader.
//!
//! `EventReader` pulls bytes from a `std.Io.Reader`, frames ONE logical line at
//! a time (a section header, a key/value with its continuations, or a comment)
//! over a bounded sliding buffer, and emits each as an `Event`. Because INI is
//! line-oriented, peak buffer occupancy is one logical line: the buffer holds
//! the line currently being framed plus at most one read-chunk of look-ahead,
//! never the whole document.
//!
//! `materialize` and `ValueStream` reuse the buffered `parser.parse` over raw
//! byte ranges so a streamed compose can never diverge from a buffered parse:
//! `materialize` parses the whole remaining stream into one `Value`, while
//! `ValueStream` parses one top-level section per `next` call.
//!
//! Grammar scope: `EventReader.next` enforces positional, O(1) grammar --
//! `KeyBeforeSection`, `NestingTooDeep`, `LineTooLong`, invalid key charset,
//! and invalid escapes -- because each requires only bounded per-event state.
//! It does NOT enforce tree-level duplicate-key or duplicate-section policies
//! (`duplicate_keys`/`duplicate_sections == .err`): doing so requires tracking
//! all keys and sections ever seen, which destroys the bounded-memory guarantee.
//! Those policies are enforced by the compose layer -- `materialize`,
//! `ValueStream`, and buffered `parse` -- which build the full section tree. A
//! consumer needing full grammar validation (including duplicate detection)
//! should use one of those interfaces.
//!
//! Borrow contract: an `Event`'s payload slices (`name`, `key`, `value`, ...)
//! are valid ONLY until the next `next()` call. Copy anything that must outlive
//! it.

const std = @import("std");

const parser = @import("parser.zig");
const value = @import("value.zig");
const dialect = @import("dialect.zig");
const escape = @import("escape.zig");
const tokenizer = @import("tokenizer.zig");

const Dialect = dialect.Dialect;
const LineKind = tokenizer.LineKind;
const ClassifyState = tokenizer.ClassifyState;
const classifyLine = tokenizer.classifyLine;

pub const Value = value.Value;
pub const Span = value.Span;
pub const Diagnostic = parser.Diagnostic;
pub const ParseOptions = parser.ParseOptions;

/// Errors a streaming parse can surface: the buffered parser's grammar errors,
/// allocator failure, and reader failure.
pub const StreamError = parser.Error || std.Io.Reader.ShortError;

/// A single streaming event. Payload slices are valid only until the next
/// `next()` call (see module doc).
pub const Event = union(enum) {
    section_header: struct { name: []const u8, subsection: ?[]const u8, span: Span },
    key_value: struct { key: []const u8, value: []const u8, span: Span },
    comment: struct { text: []const u8, span: Span },
    end_of_input,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Join `primary` with its continuation lines into one value, mirroring the
/// buffered parser's continuation handling exactly so streamed values match.
/// Segments append into a single buffer, so N continuations cost O(N) total
/// rather than recopying the accumulated value per line.
fn joinContinuations(a: std.mem.Allocator, d: Dialect, primary: []const u8, conts: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (conts.len == 0) return primary;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, primary);
    for (conts) |cont| {
        switch (d.line_continuation) {
            .indent => {
                try buf.append(a, '\n');
                try buf.appendSlice(a, trim(cont));
            },
            .backslash => {
                if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\\') buf.items.len -= 1;
                try buf.appendSlice(a, std.mem.trimEnd(u8, cont, " \t\r"));
            },
            .none => {},
        }
    }
    return buf.items;
}

const Phys = struct { content_end: usize, line_end: usize };

/// Outcome of scanning for a physical line's terminator. `need_more` carries
/// the offset to resume the terminator search from on the next pull, so framing
/// one L-byte line costs O(L) total rather than O(L^2) across re-scans.
const Scan = union(enum) {
    line: Phys,
    need_more: usize,
};

/// Locate the next physical-line terminator at or after `from`: `content_end`
/// excludes the newline, `line_end` is one past the newline sequence (both are
/// absolute offsets, independent of where the line's content began). `need_more`
/// (with a resume offset) when the terminator is not yet buffered and the reader
/// has not ended; a lone trailing `\r` counts as incomplete, since the `\n` of a
/// CRLF may be split across the next chunk.
fn scanPhysLine(bytes: []const u8, from: usize, ended: bool) Scan {
    var e = from;
    while (e < bytes.len and bytes[e] != '\n' and bytes[e] != '\r') e += 1;
    if (e == bytes.len) {
        if (!ended) return .{ .need_more = e };
        return .{ .line = .{ .content_end = e, .line_end = e } };
    }
    if (bytes[e] == '\r') {
        if (e + 1 == bytes.len) {
            if (!ended) return .{ .need_more = e };
            return .{ .line = .{ .content_end = e, .line_end = e + 1 } };
        }
        if (bytes[e + 1] == '\n') return .{ .line = .{ .content_end = e, .line_end = e + 2 } };
        return .{ .line = .{ .content_end = e, .line_end = e + 1 } };
    }
    return .{ .line = .{ .content_end = e, .line_end = e + 1 } };
}

/// One framed logical line. `raw` is the whole line including its newline(s)
/// and continuations; `primary` is the leading physical line's content;
/// `conts` are continuation physical-line contents. All borrow the framer's
/// buffer and are valid only until the next `LineFramer.next`.
const LogicalLine = struct {
    kind: LineKind,
    primary: []const u8,
    conts: []const []const u8,
    raw: []const u8,
    start: u64,
};

const Computed = struct {
    len: usize,
    kind: LineKind,
    state_after: ClassifyState,
};

/// Reader-backed logical-line framer over a bounded sliding buffer. The line
/// returned by `next` stays valid until the following `next` call, which first
/// compacts the previously framed line out of the buffer.
const LineFramer = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    d: Dialect,
    max_line_len: usize,

    buf: std.ArrayList(u8) = .empty,
    conts: std.ArrayList([]const u8) = .empty,
    base: u64 = 0,
    ended: bool = false,
    state: ClassifyState = .{},
    pending: usize = 0,
    bom_checked: bool = false,

    const chunk = 4096;

    fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, d: Dialect, max_line_len: usize) LineFramer {
        return .{ .gpa = gpa, .reader = reader, .d = d, .max_line_len = max_line_len };
    }

    fn deinit(self: *LineFramer) void {
        self.buf.deinit(self.gpa);
        self.conts.deinit(self.gpa);
    }

    /// Strip a leading UTF-8 BOM (EF BB BF) once at stream start.
    /// Waits until 3 bytes are buffered or EOF before deciding, so a BOM
    /// split across read chunks is handled correctly. Only called once
    /// (guarded by bom_checked).
    fn stripBom(self: *LineFramer) StreamError!void {
        while (self.buf.items.len < 3 and !self.ended) try self.pull();
        if (std.mem.startsWith(u8, self.buf.items, "\xEF\xBB\xBF")) self.compact(3);
    }

    fn pull(self: *LineFramer) StreamError!void {
        var tmp: [chunk]u8 = undefined;
        const n = try self.reader.readSliceShort(&tmp);
        if (n == 0) {
            self.ended = true;
            return;
        }
        if (n < tmp.len) self.ended = true;
        try self.buf.appendSlice(self.gpa, tmp[0..n]);
    }

    fn compact(self: *LineFramer, consumed: usize) void {
        if (consumed == 0) return;
        const keep = self.buf.items.len - consumed;
        std.mem.copyForwards(u8, self.buf.items[0..keep], self.buf.items[consumed..]);
        self.buf.shrinkRetainingCapacity(keep);
    }

    /// Drop the previously framed line, advancing `base` past it.
    fn flush(self: *LineFramer) void {
        if (self.pending == 0) return;
        self.compact(self.pending);
        self.base += self.pending;
        self.pending = 0;
    }

    /// Pull bytes until the buffer holds one complete logical line (header,
    /// comment, blank, or key/value plus its continuations), returning its
    /// byte length, kind, and resulting continuation state. Null when only EOF
    /// remains.
    fn computeLogical(self: *LineFramer) StreamError!?Computed {
        if (!self.bom_checked) {
            self.bom_checked = true;
            try self.stripBom();
        }
        while (true) {
            if (self.buf.items.len == 0) {
                if (self.ended) return null;
                try self.pull();
                continue;
            }
            // Resume the terminator scan across pulls so a long primary line is
            // framed in O(line). A newline-free run trips the cap mid-scan,
            // having buffered at most max_line_len plus one read chunk.
            var scan: usize = 0;
            const first = while (true) {
                switch (scanPhysLine(self.buf.items, scan, self.ended)) {
                    .line => |p| break p,
                    .need_more => |c| {
                        scan = c;
                        if (self.buf.items.len > self.max_line_len) return error.LineTooLong;
                        try self.pull();
                    },
                }
            };
            var st = self.state;
            const kind = classifyLine(self.buf.items[0..first.content_end], self.d, &st);
            var len = first.line_end;
            var st_after = st;
            if (len > self.max_line_len) return error.LineTooLong;

            // A git inline key trailing a header (`[s] k = v \`) continues onto
            // the next line just like a normal key; classifyLine seeds st.git in
            // that case, so collect the continuation lines into this same
            // logical line and feed them to the inline kv.
            const collects_cont = self.d.line_continuation != .none and
                (kind == .key_value or (kind == .section_header and st_after.git != null));
            if (collects_cont) {
                // Under indent continuation, blank lines are tentatively
                // absorbed: committed into the logical line if a real
                // continuation follows, discarded (backtracked) otherwise.
                // saved_len checkpoints the position before the current blank
                // run so a backtrack does not touch st_after (blank lines leave
                // it unchanged per classifyLine).
                var saved_len: usize = len;
                var in_blank_run: bool = false;

                inner: while (true) {
                    if (len >= self.buf.items.len) {
                        if (self.ended) break :inner;
                        try self.pull();
                        continue;
                    }
                    // Resume the continuation-line scan across pulls as well, so
                    // one huge continuation line is also framed in O(line).
                    var cscan = len;
                    const npl = while (true) {
                        switch (scanPhysLine(self.buf.items, cscan, self.ended)) {
                            .line => |p| break p,
                            .need_more => |c| {
                                cscan = c;
                                if (self.buf.items.len > self.max_line_len) return error.LineTooLong;
                                try self.pull();
                            },
                        }
                    };
                    var st2 = st_after;
                    const nkind = classifyLine(self.buf.items[len..npl.content_end], self.d, &st2);
                    if (nkind == .blank and self.d.line_continuation == .indent) {
                        if (!in_blank_run) {
                            saved_len = len;
                            in_blank_run = true;
                        }
                        len = npl.line_end;
                        if (len > self.max_line_len) return error.LineTooLong;
                        continue;
                    }
                    if (nkind != .continuation) {
                        // No continuation follows; discard tentative blanks.
                        if (in_blank_run) len = saved_len;
                        break :inner;
                    }
                    // Real continuation: commit absorbed blanks and advance.
                    in_blank_run = false;
                    len = npl.line_end;
                    st_after = st2;
                    if (len > self.max_line_len) return error.LineTooLong;
                }
                // Discard trailing blank run (ended with no continuation).
                if (in_blank_run) len = saved_len;
            }
            return .{ .len = len, .kind = kind, .state_after = st_after };
        }
    }

    /// Split `buf[0..len]` into its primary content and continuation contents.
    fn collectPhys(self: *LineFramer, len: usize) StreamError![]const u8 {
        self.conts.clearRetainingCapacity();
        const window = self.buf.items[0..len];
        var off: usize = 0;
        var idx: usize = 0;
        var primary: []const u8 = window[0..0];
        while (off < len) {
            const pl = scanPhysLine(window, off, true).line;
            const content = window[off..pl.content_end];
            if (idx == 0) primary = content else try self.conts.append(self.gpa, content);
            off = pl.line_end;
            idx += 1;
        }
        return primary;
    }

    fn next(self: *LineFramer) StreamError!?LogicalLine {
        self.flush();
        const c = (try self.computeLogical()) orelse return null;
        const primary = try self.collectPhys(c.len);
        self.state = c.state_after;
        self.pending = c.len;
        return .{
            .kind = c.kind,
            .primary = primary,
            .conts = self.conts.items,
            .raw = self.buf.items[0..c.len],
            .start = self.base,
        };
    }
};

/// Reader-backed INI event reader. See the module doc for the framing, bounded
/// memory, borrow contract, and grammar scope.
/// Streaming parses run per item against a caller-resettable arena, so they
/// must not grow caller-persistent containers from it: `errors` and `spans`
/// are buffered-parse features and are not populated by the streaming value
/// paths. Line-level diagnostics from the reader itself (which are grown
/// with the reader's gpa) are unaffected.
fn sanitizedOptions(options: parser.ParseOptions) parser.ParseOptions {
    var o = options;
    o.errors = null;
    o.spans = null;
    return o;
}

pub const EventReader = struct {
    gpa: std.mem.Allocator,
    options: ParseOptions,
    framer: LineFramer,
    ev_arena: std.heap.ArenaAllocator,
    finished: bool = false,
    /// True once any `section_header` event has been successfully parsed. Guards
    /// `KeyBeforeSection` with O(1) state: set on the first valid header, never
    /// reset. Keys before ANY header in a no-global-keys dialect are rejected.
    seen_header: bool = false,
    /// A git inline key trailing a section header (`[s] k = v`) produces two
    /// events from one physical line; the second is stashed here and returned
    /// before the next line is framed. Its payloads live in `ev_arena`, so the
    /// arena is not reset on the call that returns it.
    pending: ?Event = null,

    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) EventReader {
        return .{
            .gpa = gpa,
            .options = options,
            .framer = LineFramer.init(gpa, reader, options.dialect, options.max_line_len),
            .ev_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *EventReader) void {
        self.framer.deinit();
        self.ev_arena.deinit();
    }

    /// Current capacity of the internal sliding buffer. For the bounded-memory
    /// property it stays proportional to one logical line plus a read chunk,
    /// never the whole stream.
    pub fn bufCapacity(self: *const EventReader) usize {
        return self.framer.buf.capacity;
    }

    pub fn next(self: *EventReader) StreamError!?Event {
        if (self.finished) return null;
        if (self.pending) |ev| {
            self.pending = null;
            return ev;
        }
        _ = self.ev_arena.reset(.retain_capacity);
        while (true) {
            const ll = (try self.framer.next()) orelse {
                self.finished = true;
                return .end_of_input;
            };
            switch (ll.kind) {
                .blank, .continuation => continue,
                .comment => return try self.commentEvent(ll),
                .section_header => if (try self.headerEvent(ll)) |ev| return ev else continue,
                .key_value => if (try self.kvEvent(ll)) |ev| return ev else continue,
            }
        }
    }

    /// Compose the remaining stream into one `Value` via the buffered parser,
    /// so a streamed materialize cannot diverge from `parse`. Intended to be
    /// called before draining events; it parses from the current position to
    /// end of input.
    pub fn materialize(self: *EventReader, arena: std.mem.Allocator) StreamError!Value {
        self.framer.flush();
        while (!self.framer.ended) try self.framer.pull();
        const src = try arena.dupe(u8, self.framer.buf.items);
        return parser.parse(arena, src, sanitizedOptions(self.options));
    }

    fn spanOf(self: *const EventReader, ll: LogicalLine) Span {
        _ = self;
        return .{
            .start = ll.start,
            .end = ll.start + ll.primary.len,
        };
    }

    fn lineFailAt(self: *EventReader, span: Span, err: parser.Error, msg: []const u8) StreamError!?Event {
        if (self.options.errors) |sink| {
            sink.append(self.gpa, .{ .message = msg, .span = span }) catch return error.OutOfMemory;
            return null;
        }
        return err;
    }

    fn commentEvent(self: *EventReader, ll: LogicalLine) StreamError!Event {
        const a = self.ev_arena.allocator();
        return .{ .comment = .{ .text = try a.dupe(u8, trim(ll.primary)), .span = self.spanOf(ll) } };
    }

    fn headerEvent(self: *EventReader, ll: LogicalLine) StreamError!?Event {
        const a = self.ev_arena.allocator();
        const d = self.options.dialect;
        const span = self.spanOf(ll);
        const parts = parser.splitHeader(ll.primary, d) catch |err| {
            return self.lineFailAt(span, error.MalformedSectionHeader, parser.headerSyntaxMessage(err));
        };
        // A subsection occupies depth 2 (section=1, subsection=2); mirrors the
        // buffered parser's openSection depth guard in openHeader.
        const depth: usize = if (parts.subsection != null) 2 else 1;
        if (depth > self.options.max_depth) {
            return self.lineFailAt(span, error.NestingTooDeep, "section nesting exceeds max_depth");
        }
        const header: Event = .{ .section_header = .{
            .name = try a.dupe(u8, parts.name),
            .subsection = if (parts.subsection) |raw_sub| try escape.unescapeSubsection(a, raw_sub) else null,
            .span = span,
        } };
        // Mark first valid header so buildKv can enforce KeyBeforeSection.
        self.seen_header = true;
        // git parses non-comment trailing content as an inline key in this
        // section; the kv is emitted as the next event. Build it eagerly so a
        // charset/grammar error surfaces here, matching the buffered parser.
        if (d.quoting == .git and parts.rest.len > 0 and
            std.mem.indexOfScalar(u8, d.comment_chars, parts.rest[0]) == null)
        {
            self.pending = (try self.buildKv(parts.rest, ll.conts, span)) orelse return header;
        }
        return header;
    }

    fn kvEvent(self: *EventReader, ll: LogicalLine) StreamError!?Event {
        return self.buildKv(ll.primary, ll.conts, self.spanOf(ll));
    }

    /// Build a key_value event from one primary line plus its continuations,
    /// applying the dialect's whitespace, comment, quoting, and charset rules
    /// identically to the buffered parser's `parseKvContent`.
    fn buildKv(self: *EventReader, content: []const u8, conts: []const []const u8, span: Span) StreamError!?Event {
        const a = self.ev_arena.allocator();
        const d = self.options.dialect;

        const ai = tokenizer.findAssign(content, d.assign_chars) orelse {
            if (!d.allow_no_value) return self.lineFailAt(span, error.ExpectedAssignment, "expected assignment, found none");
            const bare = trim(content);
            if (bare.len == 0) return self.lineFailAt(span, error.EmptyKey, "empty key");
            if (!self.seen_header and !d.global_keys) {
                return self.lineFailAt(span, error.KeyBeforeSection, "key appears before any section header");
            }
            if (d.quoting == .git and !parser.validGitKey(bare)) {
                return self.lineFailAt(span, error.InvalidKey, "invalid key charset");
            }
            // git stores a bare key as an empty value (its raw-empty contract).
            return .{ .key_value = .{ .key = try a.dupe(u8, bare), .value = "", .span = span } };
        };
        const raw_key = content[0..ai];
        if (trim(raw_key).len == 0) return self.lineFailAt(span, error.EmptyKey, "empty key before assignment");
        if (!self.seen_header and !d.global_keys) {
            return self.lineFailAt(span, error.KeyBeforeSection, "key appears before any section header");
        }
        const key_src = if (d.trim_whitespace) trim(raw_key) else raw_key;
        if (d.quoting == .git and !parser.validGitKey(key_src)) {
            return self.lineFailAt(span, error.InvalidKey, "invalid key charset");
        }

        const final = if (d.quoting == .git)
            // The shared scanner handles comment stripping, escapes, quotes, and
            // continuation joins identically to the buffered parser.
            escape.decode(a, content[ai + 1 ..], conts) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidEscape => return self.lineFailAt(span, error.InvalidEscape, "invalid backslash escape in value"),
                error.UnterminatedQuote => return self.lineFailAt(span, error.UnterminatedQuote, "unterminated quoted value"),
            }
        else blk: {
            var pv = content[ai + 1 ..];
            if (d.inline_comments) pv = parser.stripInlineComment(pv, d.comment_chars);
            if (d.trim_whitespace) pv = trim(pv);
            if (d.strip_value_quotes and escape.hasSurroundingQuotePair(pv)) pv = pv[1 .. pv.len - 1];
            break :blk try joinContinuations(a, d, pv, conts);
        };

        return .{ .key_value = .{ .key = try a.dupe(u8, key_src), .value = try a.dupe(u8, final), .span = span } };
    }
};

/// Value-composition layer over the line framer: yields one top-level section
/// per `next` call. Each unit's raw bytes are parsed with the buffered parser
/// so the streamed values match a buffered parse of the same bytes. The caller
/// resets `item_arena` between calls, bounding working memory to one section.
pub const ValueStream = struct {
    gpa: std.mem.Allocator,
    options: ParseOptions,
    framer: LineFramer,
    carry: ?[]u8 = null,

    pub fn fromReader(gpa: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ValueStream {
        return .{
            .gpa = gpa,
            .options = options,
            .framer = LineFramer.init(gpa, reader, options.dialect, options.max_line_len),
        };
    }

    pub fn deinit(self: *ValueStream) void {
        if (self.carry) |c| self.gpa.free(c);
        self.framer.deinit();
    }

    pub fn next(self: *ValueStream, item_arena: std.mem.Allocator) StreamError!?Value {
        var acc: std.ArrayList(u8) = .empty;
        var have_unit = false;

        if (self.carry) |c| {
            try acc.appendSlice(item_arena, c);
            self.gpa.free(c);
            self.carry = null;
            have_unit = true;
        }

        while (try self.framer.next()) |ll| {
            switch (ll.kind) {
                .section_header => {
                    if (!have_unit) {
                        try acc.appendSlice(item_arena, ll.raw);
                        have_unit = true;
                    } else {
                        self.carry = try self.gpa.dupe(u8, ll.raw);
                        break;
                    }
                },
                .blank, .comment => {
                    if (have_unit) try acc.appendSlice(item_arena, ll.raw);
                },
                .key_value, .continuation => {
                    try acc.appendSlice(item_arena, ll.raw);
                    have_unit = true;
                },
            }
        }

        if (!have_unit) return null;
        return try parser.parse(item_arena, acc.items, sanitizedOptions(self.options));
    }
};

const testing = std.testing;
const G = Dialect.gitconfig;

fn parseBuffered(arena: std.mem.Allocator, src: []const u8, d: Dialect) !Value {
    return parser.parse(arena, src, .{ .dialect = d });
}

test "EventReader yields headers and key-values" {
    const src = "[remote \"o\"]\n\turl = u\n";
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = G });
    defer er.deinit();
    const e0 = (try er.next()).?;
    try testing.expectEqualStrings("remote", e0.section_header.name);
    try testing.expectEqualStrings("o", e0.section_header.subsection.?);
    const e1 = (try er.next()).?;
    try testing.expectEqualStrings("url", e1.key_value.key);
    try testing.expectEqualStrings("u", e1.key_value.value);
    try testing.expect((try er.next()).? == .end_of_input);
}

test "EventReader emits comments and end_of_input" {
    const src = "; hi\n[s]\nk = v\n";
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = Dialect.strict });
    defer er.deinit();
    const e0 = (try er.next()).?;
    try testing.expectEqualStrings("; hi", e0.comment.text);
    try testing.expect((try er.next()).? == .section_header);
    try testing.expect((try er.next()).? == .key_value);
    try testing.expect((try er.next()).? == .end_of_input);
    try testing.expect((try er.next()) == null);
}

test "streaming materialize equals buffered parse over the corpus shape" {
    const src = "[a]\nk = 1\n[b \"x\"]\nm = 2\nm = 3\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const buffered = try parseBuffered(arena.allocator(), src, G);
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(arena.allocator(), &fbs, .{ .dialect = G });
    const streamed = try er.materialize(arena.allocator());
    try testing.expectEqualStrings(buffered.get("a.k").?.string, streamed.get("a.k").?.string);
    try testing.expectEqual(buffered.get("b.x.m").?.list.len, streamed.get("b.x.m").?.list.len);
}

const cross_cases = [_]struct { src: []const u8, d: Dialect, key: []const u8, want: []const u8 }{
    .{ .src = "[s]\nk = a \\\nb\n", .d = G, .key = "k", .want = "a b" },
    .{ .src = "[core]\n\ty = one \\\n two\n", .d = G, .key = "y", .want = "one  two" },
    .{ .src = "[s]\nx = \"a b\"\n", .d = G, .key = "x", .want = "a b" },
    .{ .src = "[s]\nkey : line one\n    line two\n", .d = Dialect.generic, .key = "key", .want = "line one\nline two" },
    .{ .src = "[Sec]\nKey = v\n", .d = Dialect.generic, .key = "key", .want = "v" },
    // P5: blank lines within indent continuation are preserved as empty lines.
    .{ .src = "[s]\nk = a\n\n    b\n", .d = Dialect.generic, .key = "k", .want = "a\n\nb" },
    .{ .src = "[s]\nk = a\n\n\n    b\n", .d = Dialect.generic, .key = "k", .want = "a\n\n\nb" },
};

test "key_value events finalize values like the buffered parser" {
    for (cross_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var fbs = std.Io.Reader.fixed(c.src);
        var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = c.d });
        defer er.deinit();
        var got: ?[]const u8 = null;
        while (try er.next()) |ev| {
            switch (ev) {
                .end_of_input => break,
                .key_value => |kv| {
                    const folded = if (c.d.case_insensitive_keys) try std.ascii.allocLowerString(arena.allocator(), kv.key) else kv.key;
                    if (std.mem.eql(u8, folded, c.key)) got = try arena.allocator().dupe(u8, kv.value);
                },
                else => {},
            }
        }
        try testing.expect(got != null);
        testing.expectEqualStrings(c.want, got.?) catch |e| {
            std.debug.print("event-value mismatch on:\n{s}\n", .{c.src});
            return e;
        };
    }
}

// Flatten a buffered Value into ordered "path = value" pairs (section names and
// keys folded to lowercase to match git's case folding; subsections verbatim).
fn flattenBuffered(a: std.mem.Allocator, out: *std.ArrayList([]const u8), val: Value, prefix: []const u8, fold: bool) !void {
    switch (val) {
        .section => |sec| {
            for (sec.entries) |entry| {
                const seg = if (fold) try std.ascii.allocLowerString(a, entry.key) else entry.key;
                const path = if (prefix.len == 0) seg else try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, seg });
                // Subsection names (depth 2 under git) are stored verbatim; the
                // fold flag is dropped one level down by the section walk itself.
                try flattenBuffered(a, out, entry.value, path, fold);
            }
        },
        .string => |s| try out.append(a, try std.fmt.allocPrint(a, "{s} = {s}", .{ prefix, s })),
        .list => |items| for (items) |s| try out.append(a, try std.fmt.allocPrint(a, "{s} = {s}", .{ prefix, s })),
    }
}

// Drain an EventReader into the same ordered "path = value" shape, folding
// section/key names but keeping the decoded subsection verbatim.
fn flattenStream(a: std.mem.Allocator, src: []const u8, d: Dialect) ![]const []const u8 {
    var r = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(a, &r, .{ .dialect = d });
    defer er.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    var cur: []const u8 = "";
    while (try er.next()) |ev| switch (ev) {
        .end_of_input => break,
        .section_header => |h| {
            const name = if (d.case_insensitive_sections) try std.ascii.allocLowerString(a, h.name) else h.name;
            cur = if (h.subsection) |sub| try std.fmt.allocPrint(a, "{s}.{s}", .{ name, sub }) else name;
        },
        .key_value => |kv| {
            const key = if (d.case_insensitive_keys) try std.ascii.allocLowerString(a, kv.key) else kv.key;
            try out.append(a, try std.fmt.allocPrint(a, "{s}.{s} = {s}", .{ cur, key, kv.value }));
        },
        .comment => {},
    };
    return out.items;
}

test "EventReader payloads byte-match the buffered parser across gitconfig inputs" {
    // Covers P1 (escape-aware comment), P2 (comment on a continuation line),
    // P3 (backslash inside a comment), quoting, escapes, subsection escapes,
    // multi-value, and bare keys. The stream and the buffered parser share the
    // value scanner, so every payload must agree byte-for-byte.
    const inputs = [_][]const u8{
        "[s]\n\tk = a\\\" ; b\n", // P1 -> a"
        "[s]\n\tk = a \\\n  b ; c\n", // P2 -> a   b
        "[s]\n\tk = a ; c \\\nb\n", // P3 -> k=a, b=""
        "[core]\n\tx = \"a b\"\n\ty = one \\\n two\n\tbare\n",
        "[core]\n\twith-tab = \"col1\\tcol2\"\n\twith-bs = \"p\\\\q\"\n",
        "[remote \"o\"]\n\tpush = a\n\tpush = b\n\turl = git@example.com\n",
        "[section \"path\\\\to\\\\dir\"]\n\tkey = v\n",
        "[t]\n\twith-hash = before # cmt\n\tquoted-hash = \"v # not\"\n",
        "[t]\n\tinterior = a\tb\n\ttrailing = a   \n",
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (inputs) |src| {
        const buffered = try parser.parse(a, src, .{ .dialect = G });
        var bflat: std.ArrayList([]const u8) = .empty;
        try flattenBuffered(a, &bflat, buffered, "", true);
        const sflat = try flattenStream(a, src, G);
        testing.expectEqual(bflat.items.len, sflat.len) catch |e| {
            std.debug.print("count mismatch on:\n{s}\nbuffered={d} stream={d}\n", .{ src, bflat.items.len, sflat.len });
            return e;
        };
        for (bflat.items, sflat) |b, s| {
            testing.expectEqualStrings(b, s) catch |e| {
                std.debug.print("payload mismatch on:\n{s}\nbuffered={s}\nstream  ={s}\n", .{ src, b, s });
                return e;
            };
        }
    }
}

test "EventReader rejects invalid escapes like the buffered parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "[s]\n\tk = a\\xb\n", "[s]\n\tk = a\\zb\n", "[s]\n\tk = a\\;b\n" }) |src| {
        try testing.expectError(error.InvalidEscape, parser.parse(arena.allocator(), src, .{ .dialect = G }));
        var r = std.Io.Reader.fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = G });
        defer er.deinit();
        try testing.expectError(error.InvalidEscape, drainForError(&er));
    }
}

fn drainForError(er: *EventReader) StreamError!void {
    while (try er.next()) |ev| {
        if (ev == .end_of_input) break;
    }
}

test "EventReader rejects an unmatched-quote header without crashing (matches buffered)" {
    // A lone opening quote as the last inner byte once sliced
    // inner[q + 1 .. inner.len - 1] with start>end; both parsers must report a
    // clean MalformedSectionHeader instead of an out-of-bounds slice.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "[x\"]\n", "[\"]\n", "[a\"]\n", "[\"x]\n", "[TD6H47\"]\n\tk = v\n" }) |src| {
        try testing.expectError(error.MalformedSectionHeader, parser.parse(arena.allocator(), src, .{ .dialect = G }));
        var r = std.Io.Reader.fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = G });
        defer er.deinit();
        try testing.expectError(error.MalformedSectionHeader, drainForError(&er));
    }
}

test "regression: buffered parse matches EventReader events for repeated continued key" {
    // Each occurrence of the key has its own backslash continuation. The
    // streaming EventReader processes each kv independently (no shared state).
    // The buffered parser must produce the same per-occurrence values; any
    // cont_buf leakage across occurrences would make them disagree.
    const S = Dialect.systemd;
    const src = "[s]\nk=a\\\nseg1\nk=b\\\nseg2\n";

    // Collect values from the event stream in order.
    var ev_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer ev_arena.deinit();
    var stream_vals: std.ArrayList([]const u8) = .empty;
    {
        var fbs = std.Io.Reader.fixed(src);
        var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = S });
        defer er.deinit();
        while (try er.next()) |ev| {
            switch (ev) {
                .end_of_input => break,
                .key_value => |kv| {
                    if (std.mem.eql(u8, kv.key, "k"))
                        try stream_vals.append(ev_arena.allocator(), try ev_arena.allocator().dupe(u8, kv.value));
                },
                else => {},
            }
        }
    }

    // Buffered parse must produce the same list.
    var parse_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer parse_arena.deinit();
    const root = try parseBuffered(parse_arena.allocator(), src, S);
    const parsed = root.get("s.k").?.list;

    try testing.expectEqual(stream_vals.items.len, parsed.len);
    for (stream_vals.items, parsed) |sv, pv| {
        try testing.expectEqualStrings(sv, pv);
    }
}

test "stream classify matches the tokenizer line classification" {
    const docs = [_]struct { src: []const u8, d: Dialect }{
        .{ .src = "; c\n[s]\nk = a \\\nb\n\n[t]\nx=1\n", .d = G },
        .{ .src = "[s]\nkey = v\n    cont\nother = z\n# c\n", .d = Dialect.generic },
        .{ .src = "[a]\nk=1\n[b]\nk=2\n", .d = Dialect.strict },
    };
    for (docs) |doc| {
        var tz = tokenizer.Tokenizer.init(doc.src, doc.d);
        var st: ClassifyState = .{};
        while (tz.next()) |tok| {
            const content = doc.src[tok.span.start..tok.span.end];
            const got = classifyLine(content, doc.d, &st);
            try testing.expectEqual(tok.kind, got);
        }
    }
}

const EvSnap = struct {
    tag: std.meta.Tag(Event),
    s0: []const u8 = "",
    s1: []const u8 = "",
    has_s1: bool = false,
    span: Span = .{ .start = 0, .end = 0 },
};

fn snapEvent(a: std.mem.Allocator, ev: Event) !EvSnap {
    var s: EvSnap = .{ .tag = std.meta.activeTag(ev) };
    switch (ev) {
        .section_header => |h| {
            s.s0 = try a.dupe(u8, h.name);
            if (h.subsection) |x| {
                s.s1 = try a.dupe(u8, x);
                s.has_s1 = true;
            }
            s.span = h.span;
        },
        .key_value => |kv| {
            s.s0 = try a.dupe(u8, kv.key);
            s.s1 = try a.dupe(u8, kv.value);
            s.has_s1 = true;
            s.span = kv.span;
        },
        .comment => |c| {
            s.s0 = try a.dupe(u8, c.text);
            s.span = c.span;
        },
        .end_of_input => {},
    }
    return s;
}

fn drainWhole(a: std.mem.Allocator, src: []const u8, d: Dialect) ![]EvSnap {
    var r = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(a, &r, .{ .dialect = d });
    defer er.deinit();
    var out: std.ArrayList(EvSnap) = .empty;
    while (try er.next()) |ev| try out.append(a, try snapEvent(a, ev));
    return out.toOwnedSlice(a);
}

const ChunkedReader = struct {
    src: []const u8,
    pos: usize = 0,
    step: usize,
    reader: std.Io.Reader,

    fn init(src: []const u8, step: usize, buffer: []u8) ChunkedReader {
        return .{
            .src = src,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", io_r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const want = @min(self.step, self.src.len - self.pos);
        const give = @min(want, @intFromEnum(limit));
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

fn drainChunked(a: std.mem.Allocator, src: []const u8, step: usize, d: Dialect) ![]EvSnap {
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, step, &rbuf);
    var er = EventReader.fromReader(a, &cr.reader, .{ .dialect = d });
    defer er.deinit();
    var out: std.ArrayList(EvSnap) = .empty;
    while (try er.next()) |ev| try out.append(a, try snapEvent(a, ev));
    return out.toOwnedSlice(a);
}

fn expectSnapsEqual(want: []const EvSnap, got: []const EvSnap) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.tag, g.tag);
        try testing.expectEqualStrings(w.s0, g.s0);
        try testing.expectEqual(w.has_s1, g.has_s1);
        try testing.expectEqualStrings(w.s1, g.s1);
        try testing.expectEqual(w.span, g.span);
    }
}

test "P6: EventReader accepts section header with trailing comment" {
    const src = "[s] # note\nk = 1\n";
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = Dialect.generic });
    defer er.deinit();
    const e0 = (try er.next()).?;
    try testing.expectEqualStrings("s", e0.section_header.name);
    const e1 = (try er.next()).?;
    try testing.expectEqualStrings("1", e1.key_value.value);
}

test "P6: EventReader ignores junk after closing bracket for generic" {
    // configparser parity: `[s]extra` -> section `s`, trailing junk dropped.
    const src = "[s]extra\nk = 1\n";
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = Dialect.generic });
    defer er.deinit();
    const e0 = (try er.next()).?;
    try testing.expectEqualStrings("s", e0.section_header.name);
    const e1 = (try er.next()).?;
    try testing.expectEqualStrings("1", e1.key_value.value);
}

test "decision4: EventReader emits a git inline key after a section header" {
    const src = "[section] key = value\n";
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(testing.allocator, &fbs, .{ .dialect = G });
    defer er.deinit();
    const e0 = (try er.next()).?;
    try testing.expectEqualStrings("section", e0.section_header.name);
    const e1 = (try er.next()).?;
    try testing.expectEqualStrings("key", e1.key_value.key);
    try testing.expectEqualStrings("value", e1.key_value.value);
    try testing.expect((try er.next()).? == .end_of_input);
}

test "inline key continuation after a header: EventReader matches the buffered parser" {
    // A git inline key whose value continues onto the next line must decode
    // identically through the streaming reader and the buffered parser: same
    // value when valid, same error when git rejects it. The reader frames the
    // continuation lines into the header's logical line and feeds them to the
    // inline kv, so no phantom key is ever emitted.
    const ok_cases = [_]struct { src: []const u8, key: []const u8, want: []const u8 }{
        .{ .src = "[core] x = a \\\n\tb\n", .key = "core.x", .want = "a \tb" },
        .{ .src = "[s] x = a \\\nb\n", .key = "s.x", .want = "a b" },
        .{ .src = "[core] x = a \\\n b \\\n c\n", .key = "core.x", .want = "a  b  c" },
        .{ .src = "[core] x = a\n", .key = "core.x", .want = "a" },
        .{ .src = "[remote \"o\"] url = u\n", .key = "remote.o.url", .want = "u" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (ok_cases) |c| {
        const buffered = try parser.parse(a, c.src, .{ .dialect = G });
        try testing.expectEqualStrings(c.want, buffered.get(c.key).?.string);
        var r = std.Io.Reader.fixed(c.src);
        var er = EventReader.fromReader(a, &r, .{ .dialect = G });
        const streamed = try er.materialize(a);
        er.deinit();
        try testing.expectEqualStrings(c.want, streamed.get(c.key).?.string);
        // Drain the same input as discrete events to confirm exactly one kv and
        // no phantom key escaping the inline-key continuation.
        var r2 = std.Io.Reader.fixed(c.src);
        var er2 = EventReader.fromReader(a, &r2, .{ .dialect = G });
        defer er2.deinit();
        var kv_count: usize = 0;
        while (try er2.next()) |ev| switch (ev) {
            .end_of_input => break,
            .key_value => kv_count += 1,
            else => {},
        };
        try testing.expectEqual(@as(usize, 1), kv_count);
    }

    const err_cases = [_]struct { src: []const u8, err: parser.Error }{
        .{ .src = "[core] a-b = \"aa\\\ncc\n", .err = error.UnterminatedQuote },
        .{ .src = "[core] x =\\ \nmore\n", .err = error.InvalidEscape },
        .{ .src = "[core] foo \\\nbar\n", .err = error.InvalidKey },
    };
    for (err_cases) |c| {
        try testing.expectError(c.err, parser.parse(a, c.src, .{ .dialect = G }));
        var r = std.Io.Reader.fixed(c.src);
        var er = EventReader.fromReader(a, &r, .{ .dialect = G });
        defer er.deinit();
        try testing.expectError(c.err, drainForError(&er));
    }
}

test "P5: trailing blanks before a new section are not included in value" {
    const src = "[s]\nk = a\n\n    b\n\n\n[t]\nz = x\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fbs = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(arena.allocator(), &fbs, .{ .dialect = Dialect.generic });
    defer er.deinit();
    var kval: ?[]const u8 = null;
    var zval: ?[]const u8 = null;
    while (try er.next()) |ev| switch (ev) {
        .key_value => |kv| {
            if (std.mem.eql(u8, kv.key, "k")) kval = try arena.allocator().dupe(u8, kv.value);
            if (std.mem.eql(u8, kv.key, "z")) zval = try arena.allocator().dupe(u8, kv.value);
        },
        .end_of_input => break,
        else => {},
    };
    try testing.expectEqualStrings("a\n\nb", kval.?);
    try testing.expectEqualStrings("x", zval.?);
}

const chunk_cases = [_]struct { src: []const u8, d: Dialect }{
    .{ .src = "[a]\nk = 1\n[b]\ny = 2\n", .d = Dialect.strict },
    .{ .src = "[remote \"o\"]\n\turl = u\n\tpush = a\n\tpush = b\n", .d = G },
    .{ .src = "; lead comment\n[s]\nk = a \\\nb \\\nc\n# trailing\n", .d = G },
    .{ .src = "[s]\nkey : one\n    two\n    three\nz = 9\n", .d = Dialect.generic },
    .{ .src = "[Service]\nEnvironment=A=1\nEnvironment=B=2\n", .d = Dialect.systemd },
    .{ .src = "[a]\r\nk = 1\r\n[b]\r\nm = 2\r\n", .d = Dialect.strict },
    // P5: blank lines within indent continuation, trailing blanks stripped.
    .{ .src = "[s]\nkey = a\n\n    b\n\n\n[t]\nz = x\n", .d = Dialect.generic },
    // BOM: leading UTF-8 BOM stripped before line classification.
    .{ .src = "\xEF\xBB\xBF[a]\nk = 1\n[b]\ny = 2\n", .d = Dialect.strict },
};

test "event sequence identical at every chunk size including 1 byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (chunk_cases) |c| {
        const whole = try drainWhole(a, c.src, c.d);
        for ([_]usize{ 1, 2, 3, 5, 7, 13, 64 }) |step| {
            const chunked = try drainChunked(a, c.src, step, c.d);
            expectSnapsEqual(whole, chunked) catch |e| {
                std.debug.print("chunk mismatch (step={d}) on:\n{s}\n", .{ step, c.src });
                return e;
            };
        }
    }
}

test "BOM: EventReader strips leading UTF-8 BOM matching buffered parse" {
    // A BOM-prefixed gitconfig must produce the same event sequence as the
    // identical file without a BOM. The first event must be section_header,
    // not error.ExpectedAssignment. Verified 1-byte-at-a-time so each BOM
    // byte arrives in a separate read chunk.
    const body = "[remote \"o\"]\n\turl = u\n\tpush = a\n";
    const src_bom = "\xEF\xBB\xBF" ++ body;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Whole-stream: first event must be section_header, not an error.
    const whole = try drainWhole(a, src_bom, G);
    try testing.expect(whole.len > 0);
    try testing.expectEqual(std.meta.Tag(Event).section_header, whole[0].tag);
    try testing.expectEqualStrings("remote", whole[0].s0);

    // 1-byte-at-a-time: BOM bytes EF, BB, BF each arrive in separate reads.
    const chunked = try drainChunked(a, src_bom, 1, G);
    try expectSnapsEqual(whole, chunked);

    // Event sequence must equal a non-BOM drain of the same body.
    const no_bom = try drainWhole(a, body, G);
    try expectSnapsEqual(no_bom, whole);
}

test "event sequence identical 1-byte vs whole over a large multi-pull doc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try src.print(a, "[remote \"o{d}\"]\n\turl = host-{d} \\\n more\n\tpush = a\n\tpush = b\n", .{ i, i });
    }
    const whole = try drainWhole(a, src.items, G);
    const chunked = try drainChunked(a, src.items, 1, G);
    try expectSnapsEqual(whole, chunked);
}

test "bufCapacity stays bounded over a large synthetic input" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (i < 20_000) : (i += 1) {
        try src.print(src_arena.allocator(), "[s{d}]\nk = value-{d}\n", .{ i, i });
    }
    try testing.expect(src.items.len > 200_000);

    var r = std.Io.Reader.fixed(src.items);
    var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = Dialect.strict });
    defer er.deinit();

    var max_cap: usize = 0;
    while (try er.next()) |ev| {
        if (ev == .end_of_input) break;
        if (er.bufCapacity() > max_cap) max_cap = er.bufCapacity();
        // Fail fast if buffering ever grows toward the whole input.
        try testing.expect(er.bufCapacity() <= 32 * 1024);
    }
    try testing.expect(max_cap > 0);
}

test "ValueStream yields one top-level section per call" {
    const src = "[a]\nk = 1\n[b \"x\"]\nm = 2\nm = 3\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = std.Io.Reader.fixed(src);
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .dialect = G });
    defer vs.deinit();

    const v0 = (try vs.next(a)).?;
    try testing.expectEqualStrings("1", v0.get("a.k").?.string);
    try testing.expect(v0.get("b.x.m") == null);

    const v1 = (try vs.next(a)).?;
    try testing.expectEqual(@as(usize, 2), v1.get("b.x.m").?.list.len);
    try testing.expect(v1.get("a.k") == null);

    try testing.expect((try vs.next(a)) == null);
}

/// Allocator that tallies total bytes requested from a backing allocator, so a
/// quadratic streaming join is caught by a linear allocation bound rather than
/// a flaky timing measurement.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    total: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
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

test "M1 stream: continuation join allocates O(N), not O(N^2)" {
    const cases = [_]struct { d: Dialect, prefix: []const u8, cont: []const u8, last: []const u8 }{
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
        var r = std.Io.Reader.fixed(src.items);
        var er = EventReader.fromReader(counting.allocator(), &r, .{ .dialect = c.d });
        defer er.deinit();

        var segments: usize = 0;
        while (try er.next()) |ev| switch (ev) {
            .end_of_input => break,
            .key_value => |kv| segments = std.mem.count(u8, kv.value, "seg"),
            else => {},
        };
        try testing.expectEqual(n, segments);

        const bound = 200 * src.items.len;
        if (counting.total >= bound) {
            std.debug.print("M1 stream alloc {d} >= bound {d} (input {d})\n", .{ counting.total, bound, src.items.len });
            return error.QuadraticAllocation;
        }
    }
}

test "M4 stream: a logical line over max_line_len fails fast and stays bounded" {
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(src_arena.allocator(), "[s]\nk = v\n");
    var i: usize = 0;
    while (i < 1000) : (i += 1) try src.appendSlice(src_arena.allocator(), " seg\n");
    try testing.expect(src.items.len > 2000);

    var r = std.Io.Reader.fixed(src.items);
    var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = Dialect.generic, .max_line_len = 1024 });
    defer er.deinit();

    var got_err = false;
    while (true) {
        const ev = er.next() catch |e| {
            try testing.expectEqual(StreamError.LineTooLong, e);
            got_err = true;
            break;
        };
        if (ev) |x| {
            if (x == .end_of_input) break;
        } else break;
    }
    try testing.expect(got_err);
    // The framer bailed before buffering the whole oversized line.
    try testing.expect(er.bufCapacity() <= 16 * 1024);
}

/// Monotonic nanoseconds; `std.time.Timer` was dropped in 0.16. Used only to
/// put a wall-clock ceiling on the linear-framing regression tests below.
fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn newlineFree(a: std.mem.Allocator, n: usize) ![]u8 {
    const blob = try a.alloc(u8, n);
    @memset(blob, 'a');
    return blob;
}

test "R3 stream: newline-free EventReader is LineTooLong, fast, and bounded" {
    const cap: usize = 4096;
    const n: usize = 1 << 20; // 1 MiB, no newline at all
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const blob = try newlineFree(src_arena.allocator(), n);

    var r = std.Io.Reader.fixed(blob);
    var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = Dialect.generic, .max_line_len = cap });
    defer er.deinit();

    const t0 = monotonicNs();
    try testing.expectError(error.LineTooLong, drainForError(&er));
    const elapsed_ms = (monotonicNs() - t0) / std.time.ns_per_ms;

    // Linear framing (resume offset carried across pulls) completes in
    // sub-millisecond on any reasonable hardware. The ceiling is generous but
    // reliably catches a quadratic re-scan regression.
    if (elapsed_ms > 2000) {
        std.debug.print("R3 EventReader framing took {d} ms\n", .{elapsed_ms});
        return error.QuadraticTime;
    }
    // Buffered at most ~max_line_len plus one read chunk, never the whole input.
    try testing.expect(er.bufCapacity() <= 4 * cap);
}

test "R3 stream: newline-free ValueStream is LineTooLong, fast, and bounded" {
    const cap: usize = 4096;
    const n: usize = 1 << 20;
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const blob = try newlineFree(src_arena.allocator(), n);

    var r = std.Io.Reader.fixed(blob);
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .dialect = Dialect.generic, .max_line_len = cap });
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    const t0 = monotonicNs();
    try testing.expectError(error.LineTooLong, vs.next(item_arena.allocator()));
    const elapsed_ms = (monotonicNs() - t0) / std.time.ns_per_ms;
    if (elapsed_ms > 2000) {
        std.debug.print("R3 ValueStream framing took {d} ms\n", .{elapsed_ms});
        return error.QuadraticTime;
    }
    try testing.expect(vs.framer.buf.capacity <= 4 * cap);
}

test "R7: buffered parse of a huge single line trips LineTooLong like streaming" {
    const cap: usize = 4096;
    const n: usize = 1 << 20;
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();
    const vblob = try a.alloc(u8, n);
    @memset(vblob, 'v');
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "[s]\nkey = ");
    try src.appendSlice(a, vblob);
    try src.append(a, '\n');

    // The buffered parser applies the same max_line_len bound as the streaming framer.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.LineTooLong, parser.parse(arena.allocator(), src.items, .{
        .dialect = Dialect.generic,
        .max_line_len = cap,
    }));

    // Streaming reaches the same verdict on the same bytes.
    var r = std.Io.Reader.fixed(src.items);
    var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = Dialect.generic, .max_line_len = cap });
    defer er.deinit();
    try testing.expectError(error.LineTooLong, drainForError(&er));
}

fn tooLongBuffered(src: []const u8, cap: usize) bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = parser.parse(arena.allocator(), src, .{ .dialect = Dialect.generic, .max_line_len = cap }) catch |e| {
        return e == error.LineTooLong;
    };
    return false;
}

fn tooLongStream(src: []const u8, cap: usize) bool {
    var r = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = Dialect.generic, .max_line_len = cap });
    defer er.deinit();
    drainForError(&er) catch |e| return e == error.LineTooLong;
    return false;
}

test "R7: buffered parse and EventReader agree on LineTooLong across the cap" {
    const cap: usize = 256;
    var src_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer src_arena.deinit();
    const a = src_arena.allocator();

    // Indent-continued logical line swept across the cap (raw ~= 10 + 5*segs).
    for ([_]usize{ 0, 10, 40, 49, 50, 60, 120, 200 }) |segs| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "[s]\nk = v\n");
        var i: usize = 0;
        while (i < segs) : (i += 1) try src.appendSlice(a, " seg\n");
        testing.expectEqual(tooLongBuffered(src.items, cap), tooLongStream(src.items, cap)) catch |e| {
            std.debug.print("verdict mismatch (indent, segs={d})\n", .{segs});
            return e;
        };
    }
    // Single value line swept across the cap (raw ~= 7 + m).
    for ([_]usize{ 1, 100, 240, 249, 250, 260, 500 }) |m| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "[s]\nkey = ");
        var i: usize = 0;
        while (i < m) : (i += 1) try src.append(a, 'v');
        try src.append(a, '\n');
        testing.expectEqual(tooLongBuffered(src.items, cap), tooLongStream(src.items, cap)) catch |e| {
            std.debug.print("verdict mismatch (single line, m={d})\n", .{m});
            return e;
        };
    }
}

test "ValueStream over a 1-byte reader matches whole-section parses" {
    const src = "[a]\nk = 1\n[b]\nm = 2\nm = 3\n[c]\nz = 9\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, 1, &rbuf);
    var vs = ValueStream.fromReader(testing.allocator, &cr.reader, .{ .dialect = Dialect.strict });
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();

    var n: usize = 0;
    while (true) {
        _ = item_arena.reset(.retain_capacity);
        const v = (try vs.next(item_arena.allocator())) orelse break;
        switch (n) {
            0 => try testing.expectEqualStrings("1", v.get("a.k").?.string),
            1 => try testing.expectEqualStrings("3", v.get("b.m").?.string),
            2 => try testing.expectEqualStrings("9", v.get("c.z").?.string),
            else => unreachable,
        }
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    _ = a;
}

test "R8: EventReader KeyBeforeSection matches buffered for systemd/gitconfig/windows" {
    // A key before the first section header must be rejected by EventReader the
    // same way the buffered parser rejects it in all no-global-key dialects.
    const src = "k = v\n[s]\nj = w\n";
    const presets = [_]Dialect{ Dialect.systemd, Dialect.gitconfig, Dialect.windows };
    for (presets) |d| {
        // Streaming
        {
            var r = std.Io.Reader.fixed(src);
            var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = d });
            defer er.deinit();
            try testing.expectError(error.KeyBeforeSection, drainForError(&er));
        }
        // Buffered must agree.
        {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            try testing.expectError(error.KeyBeforeSection, parser.parse(arena.allocator(), src, .{ .dialect = d }));
        }
    }
}

test "R11: EventReader NestingTooDeep matches buffered for max_depth=1 + subsection" {
    // A quoted subsection sits at depth 2; with max_depth=1 both parsers must
    // reject it. A plain section (depth 1) with the same limit must still pass.
    const subsec_src = "[section \"sub\"]\nk = v\n";
    const plain_src = "[section]\nk = v\n";
    const opts: ParseOptions = .{ .dialect = Dialect.gitconfig, .max_depth = 1 };

    // Subsection -> NestingTooDeep in both.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectError(error.NestingTooDeep, parser.parse(arena.allocator(), subsec_src, opts));
    }
    {
        var r = std.Io.Reader.fixed(subsec_src);
        var er = EventReader.fromReader(testing.allocator, &r, opts);
        defer er.deinit();
        try testing.expectError(error.NestingTooDeep, drainForError(&er));
    }

    // Plain section -> accepted in both (depth 1 <= max_depth 1).
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        _ = try parser.parse(arena.allocator(), plain_src, opts);
    }
    {
        var r = std.Io.Reader.fixed(plain_src);
        var er = EventReader.fromReader(testing.allocator, &r, opts);
        defer er.deinit();
        try drainForError(&er);
    }
}

test "R9/R10: EventReader emits duplicates freely; materialize and ValueStream enforce .err policy" {
    // duplicate_keys=.err is a tree-level policy that requires unbounded state
    // (all keys seen so far). EventReader.next is a bounded streaming reader and
    // intentionally does NOT enforce it -- both key_value events are emitted.
    // materialize and ValueStream both route through parser.parse which builds
    // the full section tree and does enforce the policy.
    const dup_err_dialect: Dialect = blk: {
        var d = Dialect.strict;
        d.duplicate_keys = .err;
        break :blk d;
    };
    const src = "[s]\nk = 1\nk = 2\n";

    // EventReader.next: emits both kv events without error.
    {
        var r = std.Io.Reader.fixed(src);
        var er = EventReader.fromReader(testing.allocator, &r, .{ .dialect = dup_err_dialect });
        defer er.deinit();
        var kv_count: usize = 0;
        while (try er.next()) |ev| switch (ev) {
            .end_of_input => break,
            .key_value => kv_count += 1,
            else => {},
        };
        try testing.expectEqual(@as(usize, 2), kv_count);
    }

    // materialize: routes through parser.parse -> enforces .err.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var r = std.Io.Reader.fixed(src);
        var er = EventReader.fromReader(arena.allocator(), &r, .{ .dialect = dup_err_dialect });
        defer er.deinit();
        try testing.expectError(error.DuplicateKey, er.materialize(arena.allocator()));
    }

    // ValueStream: routes through parser.parse -> enforces .err.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var r = std.Io.Reader.fixed(src);
        var vs = ValueStream.fromReader(testing.allocator, &r, .{ .dialect = dup_err_dialect });
        defer vs.deinit();
        var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer item_arena.deinit();
        try testing.expectError(error.DuplicateKey, vs.next(item_arena.allocator()));
    }
}

test "ValueStream: errors/spans sinks are not grown from the per-item arena" {
    // Caller-persistent sinks backed by a resettable per-item arena dangle
    // after the documented reset; streaming value paths must leave them
    // untouched (they are buffered-parse features).
    var errs: std.ArrayList(parser.Diagnostic) = .empty;
    defer errs.deinit(testing.allocator);
    var spans: @import("value.zig").Spans = .empty;
    defer spans.deinit(testing.allocator);

    const src = "[a]\nx = 1\nbroken line\n[b]\ny = 2\n";
    var r: std.Io.Reader = .fixed(src);
    var vs = ValueStream.fromReader(testing.allocator, &r, .{ .errors = &errs, .spans = &spans });
    defer vs.deinit();

    var item_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer item_arena.deinit();
    while (vs.next(item_arena.allocator()) catch null) |_| {
        _ = item_arena.reset(.retain_capacity);
    }
    try testing.expectEqual(@as(usize, 0), errs.items.len);
    try testing.expectEqual(@as(usize, 0), spans.count());
}
