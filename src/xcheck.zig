//! Buffered==streaming cross-check harness.
//!
//! For every valid corpus file and a targeted adversarial battery, asserts:
//!   1. In-order EventReader events match the buffered-parse flattening
//!      (duplicate policy forced to accumulate for ordering parity with events).
//!   2. EventReader.materialize (via a 1-byte chunked reader) equals parser.parse.
//!   3. Event sequence is stable under 1/2/3/5-byte read chunks.
//!
//! The corpus root is injected by build.zig via conformance_options, mirroring
//! how conformance.zig locates its fixtures.

const std = @import("std");
const ini = @import("ini.zig");
const conformance_options = @import("conformance_options");

const Dialect = ini.Dialect;
const Value = ini.Value;
const EventReader = ini.EventReader;
const Event = ini.Event;

const corpus_root = conformance_options.corpus_path;

// ----- flattening helpers -----

// Flatten a buffered Value into ordered "path = value" lines.
// Depth 0 -> section name (fold by case_insensitive_sections).
// Depth 1 under quoted git -> subsection (verbatim, git rule).
// Depth >=1 otherwise -> key (fold by case_insensitive_keys).
fn flattenBuf(a: std.mem.Allocator, out: *std.ArrayList([]const u8), val: Value, prefix: []const u8, d: Dialect, depth: usize) !void {
    switch (val) {
        .section => |sec| {
            for (sec.entries) |entry| {
                const fold = blk: {
                    if (entry.value == .section) {
                        if (depth == 0) break :blk d.case_insensitive_sections;
                        break :blk false;
                    }
                    break :blk d.case_insensitive_keys;
                };
                const seg = if (fold) try std.ascii.allocLowerString(a, entry.key) else try a.dupe(u8, entry.key);
                const path = if (prefix.len == 0) seg else try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, seg });
                try flattenBuf(a, out, entry.value, path, d, depth + 1);
            }
        },
        .string => |s| try out.append(a, try std.fmt.allocPrint(a, "{s} = {s}", .{ prefix, s })),
        .list => |items| for (items) |s| try out.append(a, try std.fmt.allocPrint(a, "{s} = {s}", .{ prefix, s })),
    }
}

// Drain an EventReader into ordered "path = value" lines with the same folding
// as flattenBuf so the two lists are comparable.
fn flattenEvents(a: std.mem.Allocator, src: []const u8, d: Dialect) ![]const []const u8 {
    var r = std.Io.Reader.fixed(src);
    var er = EventReader.fromReader(a, &r, .{ .dialect = d });
    defer er.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    var cur: []const u8 = "";
    var have_section = false;
    while (try er.next()) |ev| switch (ev) {
        .end_of_input => break,
        .comment => {},
        .section_header => |h| {
            const name = if (d.case_insensitive_sections) try std.ascii.allocLowerString(a, h.name) else try a.dupe(u8, h.name);
            cur = if (h.subsection) |sub| try std.fmt.allocPrint(a, "{s}.{s}", .{ name, sub }) else name;
            have_section = true;
        },
        .key_value => |kv| {
            const key = if (d.case_insensitive_keys) try std.ascii.allocLowerString(a, kv.key) else try a.dupe(u8, kv.key);
            const line = if (have_section)
                try std.fmt.allocPrint(a, "{s}.{s} = {s}", .{ cur, key, kv.value })
            else
                try std.fmt.allocPrint(a, "{s} = {s}", .{ key, kv.value });
            try out.append(a, line);
        },
    };
    return out.items;
}

// Force accumulate so the buffered tree preserves every physical occurrence in
// document order, matching the event stream (which is policy-independent).
fn accumulating(d: Dialect) Dialect {
    var m = d;
    m.duplicate_keys = .accumulate;
    m.duplicate_sections = .accumulate;
    return m;
}

fn compareEventsVsBuffered(a: std.mem.Allocator, src: []const u8, d: Dialect, label: []const u8) !void {
    const acc = accumulating(d);
    const buffered = ini.parse(a, src, .{ .dialect = acc }) catch |e| {
        // A buffered parse error on a valid-corpus file would be caught by the
        // conformance suite; skip the events comparison and let it fail there.
        std.debug.print("[{s}] buffered parse error {t} (skipping events-vs-buffered)\n", .{ label, e });
        return;
    };
    var bflat: std.ArrayList([]const u8) = .empty;
    try flattenBuf(a, &bflat, buffered, "", acc, 0);
    const eflat = try flattenEvents(a, src, d);

    if (bflat.items.len != eflat.len) {
        std.debug.print("[{s}] COUNT MISMATCH buffered={d} events={d}\nsrc=<<<{s}>>>\n", .{ label, bflat.items.len, eflat.len, src });
        for (bflat.items) |b| std.debug.print("  buf: {s}\n", .{b});
        for (eflat) |e| std.debug.print("  ev : {s}\n", .{e});
        return error.CountMismatch;
    }
    for (bflat.items, eflat) |b, e| {
        if (!std.mem.eql(u8, b, e)) {
            std.debug.print("[{s}] LINE MISMATCH\n  buf: {s}\n  ev : {s}\nsrc=<<<{s}>>>\n", .{ label, b, e, src });
            return error.LineMismatch;
        }
    }
}

// ----- chunked reader (arbitrary step size) -----

const ChunkedReader = struct {
    src: []const u8,
    pos: usize = 0,
    step: usize,
    reader: std.Io.Reader,

    fn init(src: []const u8, step: usize, buffer: []u8) ChunkedReader {
        return .{
            .src = src,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = streamFn }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn streamFn(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", io_r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const want = @min(self.step, self.src.len - self.pos);
        const give = @min(want, @intFromEnum(limit));
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

// materialize over a 1-byte reader must equal a buffered parse of the same bytes.
fn compareMaterializeVsBuffered(a: std.mem.Allocator, src: []const u8, d: Dialect, label: []const u8) !void {
    const want = ini.parse(a, src, .{ .dialect = d }) catch |e| {
        // If buffered errors, materialize must error with the same code.
        var rbuf: [64]u8 = undefined;
        var cr = ChunkedReader.init(src, 1, &rbuf);
        var er = EventReader.fromReader(a, &cr.reader, .{ .dialect = d });
        defer er.deinit();
        const mres = er.materialize(a);
        if (mres) |_| {
            std.debug.print("[{s}] materialize SUCCEEDED but buffered errored {t}\nsrc=<<<{s}>>>\n", .{ label, e, src });
            return error.LineMismatch;
        } else |me| {
            if (me != e) {
                std.debug.print("[{s}] materialize err {t} != buffered err {t}\nsrc=<<<{s}>>>\n", .{ label, me, e, src });
                return error.LineMismatch;
            }
        }
        return;
    };
    var rbuf: [64]u8 = undefined;
    var cr = ChunkedReader.init(src, 1, &rbuf);
    var er = EventReader.fromReader(a, &cr.reader, .{ .dialect = d });
    defer er.deinit();
    const got = try er.materialize(a);

    var wflat: std.ArrayList([]const u8) = .empty;
    try flattenBuf(a, &wflat, want, "", d, 0);
    var gflat: std.ArrayList([]const u8) = .empty;
    try flattenBuf(a, &gflat, got, "", d, 0);

    if (wflat.items.len != gflat.items.len) {
        std.debug.print("[{s}] MATERIALIZE COUNT MISMATCH parse={d} mat={d}\nsrc=<<<{s}>>>\n", .{ label, wflat.items.len, gflat.items.len, src });
        return error.CountMismatch;
    }
    for (wflat.items, gflat.items) |x, y| {
        if (!std.mem.eql(u8, x, y)) {
            std.debug.print("[{s}] MATERIALIZE LINE MISMATCH\n  parse: {s}\n  mat  : {s}\nsrc=<<<{s}>>>\n", .{ label, x, y, src });
            return error.LineMismatch;
        }
    }
}

// Event snapshot: compact representation for chunk-stability comparison.
const Snap = struct { tag: std.meta.Tag(Event), s0: []const u8 = "", s1: []const u8 = "", has1: bool = false, sub: bool = false };

fn drain(a: std.mem.Allocator, reader: *std.Io.Reader, d: Dialect) ![]Snap {
    var er = EventReader.fromReader(a, reader, .{ .dialect = d });
    defer er.deinit();
    var out: std.ArrayList(Snap) = .empty;
    while (try er.next()) |ev| {
        var s: Snap = .{ .tag = std.meta.activeTag(ev) };
        switch (ev) {
            .section_header => |h| {
                s.s0 = try a.dupe(u8, h.name);
                if (h.subsection) |x| {
                    s.s1 = try a.dupe(u8, x);
                    s.has1 = true;
                    s.sub = true;
                }
            },
            .key_value => |kv| {
                s.s0 = try a.dupe(u8, kv.key);
                s.s1 = try a.dupe(u8, kv.value);
                s.has1 = true;
            },
            .comment => |c| s.s0 = try a.dupe(u8, c.text),
            .end_of_input => {},
        }
        try out.append(a, s);
        if (ev == .end_of_input) break;
    }
    return out.items;
}

// The event sequence must be identical regardless of how many bytes arrive per read.
fn compareChunkStability(a: std.mem.Allocator, src: []const u8, d: Dialect, label: []const u8) !void {
    var wr = std.Io.Reader.fixed(src);
    const whole = drain(a, &wr, d) catch |e| {
        // Error path: 1-byte drain must error with the same code.
        var rbuf: [64]u8 = undefined;
        var cr = ChunkedReader.init(src, 1, &rbuf);
        const cres = drain(a, &cr.reader, d);
        if (cres) |_| {
            std.debug.print("[{s}] chunk drain ok but whole errored {t}\n", .{ label, e });
            return error.LineMismatch;
        } else |ce| {
            if (ce != e) {
                std.debug.print("[{s}] chunk err {t} != whole err {t}\n", .{ label, ce, e });
                return error.LineMismatch;
            }
            return;
        }
    };
    for ([_]usize{ 1, 2, 3, 5 }) |step| {
        var rbuf: [64]u8 = undefined;
        var cr = ChunkedReader.init(src, step, &rbuf);
        const ch = try drain(a, &cr.reader, d);
        if (whole.len != ch.len) {
            std.debug.print("[{s}] CHUNK(step={d}) COUNT whole={d} chunk={d}\nsrc=<<<{s}>>>\n", .{ label, step, whole.len, ch.len, src });
            return error.CountMismatch;
        }
        for (whole, ch) |w, c| {
            if (w.tag != c.tag or w.has1 != c.has1 or w.sub != c.sub or
                !std.mem.eql(u8, w.s0, c.s0) or !std.mem.eql(u8, w.s1, c.s1))
            {
                std.debug.print("[{s}] CHUNK(step={d}) SNAP MISMATCH\n  whole: {s}|{s}\n  chunk: {s}|{s}\nsrc=<<<{s}>>>\n", .{ label, step, w.s0, w.s1, c.s0, c.s1, src });
                return error.LineMismatch;
            }
        }
    }
}

fn runAll(a: std.mem.Allocator, src: []const u8, d: Dialect, label: []const u8) !void {
    try compareEventsVsBuffered(a, src, d, label);
    try compareMaterializeVsBuffered(a, src, d, label);
    try compareChunkStability(a, src, d, label);
}

// ----- corpus walk -----

fn dialectFor(name: []const u8) Dialect {
    if (std.mem.eql(u8, name, "generic")) return Dialect.generic;
    if (std.mem.eql(u8, name, "gitconfig")) return Dialect.gitconfig;
    if (std.mem.eql(u8, name, "systemd")) return Dialect.systemd;
    if (std.mem.eql(u8, name, "windows")) return Dialect.windows;
    unreachable;
}

test "xcheck: every valid corpus file, buffered == streaming" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dialects = [_][]const u8{ "generic", "gitconfig", "systemd", "windows" };
    var total: usize = 0;
    for (dialects) |dn| {
        const d = dialectFor(dn);
        const valid_path = try std.fmt.allocPrint(a, "{s}/{s}/valid", .{ corpus_root, dn });
        var dir = try std.Io.Dir.openDirAbsolute(io, valid_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".expected")) continue;
            if (std.mem.endsWith(u8, entry.name, ".error")) continue;
            const src = try dir.readFileAlloc(io, entry.name, a, .limited(1 << 16));
            const label = try std.fmt.allocPrint(a, "{s}/{s}", .{ dn, entry.name });
            try runAll(a, src, d, label);
            total += 1;
        }
    }
    std.debug.print("xcheck: {d} corpus files passed buffered==streaming\n", .{total});
    try std.testing.expect(total >= 26);
}

test "xcheck: adversarial battery, buffered == streaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const G = Dialect.gitconfig;
    const Gen = Dialect.generic;
    const S = Dialect.systemd;
    const W = Dialect.windows;
    const St = Dialect.strict;

    const Case = struct { src: []const u8, d: Dialect };
    const cases = [_]Case{
        // gitconfig: escapes, quotes, comments, inline key, subsections
        .{ .src = "[s]\n\tk = a\\\" ; b\n", .d = G },
        .{ .src = "[s]\n\tk = a \\\n  b ; c\n", .d = G },
        .{ .src = "[s]\n\tk = a ; c \\\nb\n", .d = G },
        .{ .src = "[core]\n\tx = \"a b\"\n\ty = one \\\n two\n\tbare\n", .d = G },
        .{ .src = "[core]\n\twith-tab = \"col1\\tcol2\"\n\twith-bs = \"p\\\\q\"\n", .d = G },
        .{ .src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n\turl = x\n", .d = G },
        .{ .src = "[section \"path\\\\to\\\\dir\"]\n\tkey = v\n", .d = G },
        .{ .src = "[t]\n\twith-hash = before # cmt\n\tquoted-hash = \"v # not\"\n", .d = G },
        .{ .src = "[t]\n\tinterior = a\tb\n\ttrailing = a   \n", .d = G },
        .{ .src = "[s] inlinekey = v\n", .d = G },
        .{ .src = "[s]extra\nk = 1\n", .d = G },
        .{ .src = "[s]bare\n", .d = G },
        .{ .src = "[a.b.c]\n\tk = v\n", .d = G },
        .{ .src = "[s]\n\tk = \"  spaced  \"\n", .d = G },
        .{ .src = "[s]\n\tk = a\\nb\n", .d = G },
        .{ .src = "[s]\n\tempty =\n\tbare2\n", .d = G },
        .{ .src = "[s]\n\tk = val # not \\\n cont? \n", .d = G },
        .{ .src = "[s]\n\tmulti = \"x\\\ny\"\n", .d = G },
        .{ .src = "[s]\n\tk = a \\\n \\\n b\n", .d = G },
        // generic: indent continuation, blank-line preservation, colon assign, global keys
        .{ .src = "[s]\nkey : line one\n    line two\n", .d = Gen },
        .{ .src = "[s]\nk = a\n\n    b\n", .d = Gen },
        .{ .src = "[s]\nk = a\n\n\n    b\n", .d = Gen },
        .{ .src = "[s]\nk = a\n\n    b\n\n\n[t]\nz = x\n", .d = Gen },
        .{ .src = "topkey = v\n[s]\nk = 1\n", .d = Gen },
        .{ .src = "g1 = a\ng2 = b\n[s]\nk = 1\n", .d = Gen },
        .{ .src = "[ s ]\nk = 1\n", .d = Gen },
        .{ .src = "[s]\nKey = V\nkey = w\n", .d = Gen },
        .{ .src = "[s]\nk = val:ue\n", .d = Gen },
        .{ .src = "[s]\nk : val=ue\n", .d = Gen },
        .{ .src = "[s] # note\nk = 1\n", .d = Gen },
        .{ .src = "[s]\n  indented_key = v\n", .d = Gen },
        // systemd: backslash continuation, accumulate
        .{ .src = "[Service]\nEnvironment=A=1\nEnvironment=B=2\n", .d = S },
        .{ .src = "[s]\nk=a\\\nseg1\nk=b\\\nseg2\n", .d = S },
        .{ .src = "[s]\nExecStart=/bin/x \\\n --flag \\\n --more\n", .d = S },
        // windows: strip_value_quotes, last-wins, semicolon-only comments
        .{ .src = "[Sec]\n; c\nk=\"quoted\"\nk=2\n", .d = W },
        .{ .src = "[s]\nk=\"x\"\n", .d = W },
        .{ .src = "[s]\nk=\"unbalanced\n", .d = W },
        .{ .src = "[s]\nk=a\"b\n", .d = W },
        // strict: basics, CRLF, no trailing newline, section merge
        .{ .src = "[a]\r\nk = 1\r\n[b]\r\nm = 2\r\n", .d = St },
        .{ .src = "[s]\nk = v", .d = St },
        .{ .src = "[a]\nk=1\n[a]\nj=2\n", .d = St },
        // UTF-8 BOM
        .{ .src = "\xEF\xBB\xBF[a]\nk = 1\n", .d = St },
        .{ .src = "\xEF\xBB\xBF[remote \"o\"]\n\turl = u\n", .d = G },
        // edge cases: empty value, trailing whitespace, comment-only, blank-only, empty
        .{ .src = "[s]\nk =\n", .d = St },
        .{ .src = "[s]\nk = a   \n", .d = St },
        .{ .src = "; only a comment\n", .d = St },
        .{ .src = "\n\n\n", .d = St },
        .{ .src = "", .d = St },
    };

    var n: usize = 0;
    for (cases) |c| {
        const label = try std.fmt.allocPrint(a, "adv#{d}", .{n});
        try runAll(a, c.src, c.d, label);
        n += 1;
    }
    std.debug.print("xcheck: {d} adversarial cases passed buffered==streaming\n", .{n});
}

test "xcheck: custom-dialect field toggles, buffered == streaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var base = Dialect.strict;
    base.global_keys = true;

    // trim_whitespace on/off
    {
        var d = base;
        d.trim_whitespace = false;
        try runAll(a, "[s]\n  k  =  v  \n", d, "trim_off");
        d.trim_whitespace = true;
        try runAll(a, "[s]\n  k  =  v  \n", d, "trim_on");
    }
    // inline_comments on/off (non-git)
    {
        var d = base;
        d.inline_comments = true;
        try runAll(a, "[s]\nk = v ; trailing\n", d, "inline_on");
        d.inline_comments = false;
        try runAll(a, "[s]\nk = v ; trailing\n", d, "inline_off");
    }
    // strip_value_quotes on/off
    {
        var d = base;
        d.strip_value_quotes = true;
        try runAll(a, "[s]\nk = \"v\"\n", d, "strip_on");
        d.strip_value_quotes = false;
        try runAll(a, "[s]\nk = \"v\"\n", d, "strip_off");
    }
    // trim_section_names on/off
    {
        var d = base;
        d.trim_section_names = false;
        try runAll(a, "[ s ]\nk = v\n", d, "secname_off");
        d.trim_section_names = true;
        try runAll(a, "[ s ]\nk = v\n", d, "secname_on");
    }
    // allow_no_value
    {
        var d = base;
        d.allow_no_value = true;
        try runAll(a, "[s]\nbare\nk = v\n", d, "bare_on");
    }
    // combined: trim_whitespace=false + inline_comments + strip_value_quotes
    {
        var d = base;
        d.trim_whitespace = false;
        d.inline_comments = true;
        try runAll(a, "[s]\nk = v ; c\n", d, "combo");
    }
}
