//! Random-input fuzzer for the ini library.
//!
//! Invariants under test:
//!   - parse never panics or hangs on any input, for every dialect preset
//!   - encode of a successfully-parsed Value re-parses to a structurally-equal
//!     Value (round-trip) -- checked for every dialect preset. A value the
//!     target dialect cannot represent (encode returns UnrepresentableValue)
//!     is skipped rather than counted as a violation; any successful encode
//!     must round-trip.
//!
//! CLI:
//!   ini-fuzz [--iters N] [--seed S] [--max-input M]
//!
//! Defaults: 200,000 iterations, random seed, 4096-byte max input.

const std = @import("std");
const Io = std.Io;
const ini = @import("ini");

const Dialect = ini.Dialect;
const Value = ini.Value;
const Section = ini.Section;

const all_dialects = [_]Dialect{
    Dialect.strict,
    Dialect.windows,
    Dialect.gitconfig,
    Dialect.systemd,
    Dialect.generic,
};

// Dialects for which encode -> parse round-trips correctly.
const roundtrip_dialects = [_]Dialect{
    Dialect.strict,
    Dialect.windows,
    Dialect.gitconfig,
    Dialect.systemd,
    Dialect.generic,
};

// Reason a round-trip check failed. An enum (not an error set) so it can be
// returned as a payload of the optional without conflating "OOM" with "bug".
const RoundTripFail = enum {
    encode_failed,
    reparse_failed,
    mismatch,
};

// Reason a sort_keys stability check failed.
const SortStableFail = enum {
    encode1_failed,
    reparse_failed,
    encode2_failed,
    mismatch,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena_alloc = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    var stderr_buf: [256]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buf);
    const ew = &stderr_writer.interface;

    var iters: usize = 200_000;
    var max_input: usize = 4096;
    var seed: u64 = blk: {
        var s: u64 = undefined;
        io.random(@ptrCast(&s));
        break :blk s;
    };

    const args = try init.minimal.args.toSlice(arena_alloc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--iters") and i + 1 < args.len) {
            iters = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed") and i + 1 < args.len) {
            seed = try std.fmt.parseInt(u64, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--max-input") and i + 1 < args.len) {
            max_input = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else {
            try ew.print("usage: ini-fuzz [--iters N] [--seed S] [--max-input M]\n", .{});
            try ew.flush();
            return 2;
        }
    }

    try w.print("ini-fuzz: iters={d} seed={d} max_input={d}\n", .{ iters, seed, max_input });
    try w.flush();

    var prng: std.Random.DefaultPrng = .init(seed);
    const rng = prng.random();

    const input_buf = try gpa.alloc(u8, max_input);
    defer gpa.free(input_buf);

    var failures: usize = 0;
    var parsed_ok: usize = 0;
    var n: usize = 0;

    while (n < iters) : (n += 1) {
        const len = rng.intRangeAtMost(usize, 0, max_input);
        const input = input_buf[0..len];

        // Every fourth iteration uses biased INI-like bytes; otherwise random.
        if (rng.uintLessThan(u8, 4) < 3) {
            rng.bytes(input);
        } else {
            generateBiased(rng, input);
        }

        // No-crash check: all dialects must parse without panicking.
        for (all_dialects) |d| {
            try fuzzNoCrash(gpa, input, d);
        }

        // Round-trip check: for safe-encode dialects, parse->encode->parse must agree.
        var any_parsed_ok = false;
        for (roundtrip_dialects) |d| {
            if (try fuzzRoundTrip(gpa, input, d)) |fail| {
                failures += 1;
                try reportFailure(w, n, seed, input, d, fail);
            } else {
                // Count iterations where at least one dialect parsed the input ok.
                var arena_probe: std.heap.ArenaAllocator = .init(gpa);
                defer arena_probe.deinit();
                const probe = ini.parse(arena_probe.allocator(), input, .{ .dialect = d }) catch continue;
                _ = probe;
                any_parsed_ok = true;
            }

            // sort_keys stability: encode(sort_keys=true) is a fixed point under
            // re-parse -> re-encode(sort_keys=true).
            if (try fuzzSortStable(gpa, input, d)) |fail| {
                failures += 1;
                try reportSortStableFailure(w, n, seed, input, d, fail);
            }
        }
        if (any_parsed_ok) parsed_ok += 1;

        if ((n + 1) % 20_000 == 0) {
            try w.print("  {d:>9} iters, {d} parsed ok, {d} failures\n", .{ n + 1, parsed_ok, failures });
            try w.flush();
        }
    }

    // Streaming arm: large inputs exercise multi-pull framer resumption
    // Straddle sizes sweep a few bytes around each 4096-byte pull boundary;
    // the random bucket fills with inputs up to stream_max to cover long runs.
    const stream_max: usize = 16_384;
    const stream_buf = try gpa.alloc(u8, stream_max);
    defer gpa.free(stream_buf);

    var straddle_buf: [33]usize = undefined;
    var n_straddle: usize = 0;
    for ([_]usize{ 4096, 8192, 12288 }) |boundary| {
        var off: i64 = -5;
        while (off <= 5) : (off += 1) {
            const sz = @as(i64, @intCast(boundary)) + off;
            if (sz > 0 and @as(usize, @intCast(sz)) <= stream_max) {
                straddle_buf[n_straddle] = @as(usize, @intCast(sz));
                n_straddle += 1;
            }
        }
    }
    const straddle_sizes = straddle_buf[0..n_straddle];

    const stream_iters = iters / 4;
    var stream_failures: usize = 0;
    var multi_pull_count: usize = 0;

    var sn: usize = 0;
    while (sn < stream_iters) : (sn += 1) {
        // 1-in-8 chance: straddle size near a pull boundary.
        // Otherwise: random length strictly above 4096 so every input causes >1 pull.
        const slen: usize = if (straddle_sizes.len > 0 and rng.uintLessThan(u8, 8) == 0)
            straddle_sizes[rng.uintLessThan(usize, straddle_sizes.len)]
        else
            rng.intRangeAtMost(usize, 4097, stream_max);

        const sinput = stream_buf[0..slen];
        if (rng.uintLessThan(u8, 4) < 3) {
            rng.bytes(sinput);
        } else {
            generateBiased(rng, sinput);
        }

        if (slen > 4096) multi_pull_count += 1;

        // 1-in-20: also run materialize through the 1-byte fragmenting reader.
        const fragment = rng.uintLessThan(u8, 20) == 0;

        for (all_dialects) |d| {
            if (try fuzzStreaming(gpa, sinput, d, fragment)) |fail| {
                stream_failures += 1;
                try reportStreamFail(w, sn, seed, sinput, d, fail);
            }
        }

        if ((sn + 1) % 10_000 == 0) {
            try w.print("  stream {d:>7} iters, multi_pull={d}, {d} failures\n", .{
                sn + 1, multi_pull_count, stream_failures,
            });
            try w.flush();
        }
    }

    try w.print("stream arm: {d} iters, multi_pull={d}, {d} failures\n", .{
        stream_iters, multi_pull_count, stream_failures,
    });
    try w.flush();
    failures += stream_failures;

    try w.print("\ndone: {d} iters, {d} parsed ok, {d} failures\n", .{ n, parsed_ok, failures });
    try w.flush();
    return if (failures == 0) 0 else 1;
}

// Call parse; catch and discard expected errors. A panic/crash is the only
// failure mode -- the process exits non-zero, failing the fuzzer run.
fn fuzzNoCrash(gpa: std.mem.Allocator, input: []const u8, d: Dialect) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = ini.parse(arena.allocator(), input, .{ .dialect = d }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

// For dialects with safe encode->parse cycles, check parse->encode->parse equality.
// Returns null when the invariant holds (or when the initial parse failed), or a
// RoundTripFail variant that identifies where the cycle broke.
fn fuzzRoundTrip(gpa: std.mem.Allocator, input: []const u8, d: Dialect) !?RoundTripFail {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const v1 = ini.parse(arena.allocator(), input, .{ .dialect = d }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    ini.encode(&aw.writer, v1, .{ .dialect = d }) catch |e| switch (e) {
        // WriteFailed from an allocating writer means the backing allocator ran out of memory.
        error.WriteFailed => return error.OutOfMemory,
        // A value the dialect cannot represent is not a round-trip violation.
        error.UnrepresentableValue => return null,
        else => return .encode_failed,
    };

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    const v2 = ini.parse(arena2.allocator(), aw.written(), .{ .dialect = d }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .reparse_failed,
    };

    if (!valueEql(v1, v2)) return .mismatch;
    return null;
}

fn reportFailure(w: *Io.Writer, iter: usize, seed: u64, input: []const u8, d: Dialect, fail: RoundTripFail) !void {
    try w.print("FAIL iter={d} seed={d} dialect={s} fail={t} input_len={d}\n", .{
        iter, seed, dialectName(d), fail, input.len,
    });
    try w.print("input (escaped): \"", .{});
    for (input) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (b >= 0x20 and b < 0x7f) try w.writeByte(b) else try w.print("\\x{x:0>2}", .{b}),
    };
    try w.writeAll("\"\n");
    try w.flush();
}

// Sort stability: for safe-encode dialects, encode(sort_keys=true) must be a
// fixed point under re-parse -> re-encode(sort_keys=true). This is not a
// round-trip of the original value (sort_keys deliberately reorders it) -- it
// checks that sorting an already-sorted tree changes nothing.
// Returns null when the invariant holds (or the initial parse/encode is
// skipped for an expected reason), or a SortStableFail identifying where the
// cycle broke.
fn fuzzSortStable(gpa: std.mem.Allocator, input: []const u8, d: Dialect) !?SortStableFail {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const v1 = ini.parse(arena.allocator(), input, .{ .dialect = d }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    var aw1: Io.Writer.Allocating = .init(gpa);
    defer aw1.deinit();
    ini.encode(&aw1.writer, v1, .{ .dialect = d, .sort_keys = true }) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        error.UnrepresentableValue => return null,
        else => return .encode1_failed,
    };

    var arena2: std.heap.ArenaAllocator = .init(gpa);
    defer arena2.deinit();
    const v2 = ini.parse(arena2.allocator(), aw1.written(), .{ .dialect = d }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .reparse_failed,
    };

    var aw2: Io.Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    ini.encode(&aw2.writer, v2, .{ .dialect = d, .sort_keys = true }) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => return .encode2_failed,
    };

    if (!std.mem.eql(u8, aw1.written(), aw2.written())) return .mismatch;
    return null;
}

fn reportSortStableFailure(w: *Io.Writer, iter: usize, seed: u64, input: []const u8, d: Dialect, fail: SortStableFail) !void {
    try w.print("SORT-STABLE-FAIL iter={d} seed={d} dialect={s} fail={t} input_len={d}\n", .{
        iter, seed, dialectName(d), fail, input.len,
    });
    try w.print("input (escaped): \"", .{});
    for (input) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (b >= 0x20 and b < 0x7f) try w.writeByte(b) else try w.print("\\x{x:0>2}", .{b}),
    };
    try w.writeAll("\"\n");
    try w.flush();
}

fn dialectName(d: Dialect) []const u8 {
    if (std.meta.eql(d, Dialect.strict)) return "strict";
    if (std.meta.eql(d, Dialect.windows)) return "windows";
    if (std.meta.eql(d, Dialect.gitconfig)) return "gitconfig";
    if (std.meta.eql(d, Dialect.systemd)) return "systemd";
    if (std.meta.eql(d, Dialect.generic)) return "generic";
    return "custom";
}

fn generateBiased(rng: std.Random, out: []u8) void {
    // Bias toward bytes likely to exercise INI grammar paths.
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. = []\";#\n\t:\\";
    for (out) |*b| {
        if (rng.boolean()) {
            b.* = charset[rng.uintLessThan(usize, charset.len)];
        } else {
            b.* = rng.int(u8);
        }
    }
}

// Structural equality for Value trees.
fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .list => |items| blk: {
            if (items.len != b.list.len) break :blk false;
            for (items, b.list) |s1, s2| {
                if (!std.mem.eql(u8, s1, s2)) break :blk false;
            }
            break :blk true;
        },
        .section => |sec| sectionEql(sec, b.section),
    };
}

fn sectionEql(a: *Section, b: *Section) bool {
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |ea, eb| {
        if (!std.mem.eql(u8, ea.key, eb.key)) return false;
        if (!valueEql(ea.value, eb.value)) return false;
    }
    return true;
}

// Streaming arm

// A std.Io.Reader that delivers at most `step` bytes per read, for driving the
// framer across maximally-split pull boundaries.
const ChunkedReader = struct {
    src: []const u8,
    pos: usize = 0,
    step: usize,
    reader: Io.Reader,

    fn init(src: []const u8, step: usize, buf: []u8) ChunkedReader {
        return .{
            .src = src,
            .step = step,
            .reader = .{ .vtable = &.{ .stream = streamFn }, .buffer = buf, .seek = 0, .end = 0 },
        };
    }

    fn streamFn(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", r);
        if (self.pos >= self.src.len) return error.EndOfStream;
        const avail = self.src.len - self.pos;
        const want = @min(self.step, avail);
        const give = @min(want, @intFromEnum(limit));
        const n = try w.write(self.src[self.pos..][0..give]);
        self.pos += n;
        return n;
    }
};

// Dialect copy with both duplicate policies forced to .accumulate so the
// buffered reference tree retains every key/section occurrence, matching the
// per-event model of EventReader where every key_value is emitted regardless
// of the dialect's duplicate_keys setting.
fn accumulatePolicy(d: Dialect) Dialect {
    var m = d;
    m.duplicate_keys = .accumulate;
    m.duplicate_sections = .accumulate;
    return m;
}

const StreamFail = enum {
    materialize_verdict,
    materialize_value,
    event_verdict,
    event_multiset,
};

fn reportStreamFail(
    w: *Io.Writer,
    iter: usize,
    seed: u64,
    input: []const u8,
    d: Dialect,
    fail: StreamFail,
) !void {
    try w.print("STREAM-FAIL iter={d} seed={d} dialect={s} fail={t} input_len={d}\n", .{
        iter, seed, dialectName(d), fail, input.len,
    });
    try w.print("input (escaped): \"", .{});
    for (input) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (b >= 0x20 and b < 0x7f) try w.writeByte(b) else try w.print("\\x{x:0>2}", .{b}),
    };
    try w.writeAll("\"\n");
    try w.flush();
}

// Flatten a buffered Value tree to "path=value" strings with case-folding
// consistent with how the buffered parser stores names: section names fold at
// depth 0 when case_insensitive_sections; subsections at depth 1 are verbatim;
// key names fold when case_insensitive_keys.
fn flatBuf(
    a: std.mem.Allocator,
    v: Value,
    d: Dialect,
    prefix: []const u8,
    depth: usize,
    out: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    switch (v) {
        .string => |s| try out.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ prefix, s })),
        .list => |items| for (items) |s| try out.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ prefix, s })),
        .section => |sec| for (sec.entries) |entry| {
            const is_sec = entry.value == .section;
            const fold = if (is_sec) (depth == 0 and d.case_insensitive_sections) else d.case_insensitive_keys;
            const seg = if (fold) try std.ascii.allocLowerString(a, entry.key) else try a.dupe(u8, entry.key);
            const path = if (prefix.len == 0) seg else try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, seg });
            try flatBuf(a, entry.value, d, path, depth + 1, out);
        },
    }
}

// Drain an EventReader into "path=value" strings with the same case-folding as
// flatBuf. Returns false when the reader emits a parse error (non-OOM), so the
// caller can distinguish a verdict divergence from a clean drain.
fn flatEvents(
    a: std.mem.Allocator,
    input: []const u8,
    d: Dialect,
    out: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!bool {
    var r = std.Io.Reader.fixed(input);
    var er = ini.EventReader.fromReader(a, &r, .{ .dialect = d });
    defer er.deinit();
    var cur: []const u8 = "";
    while (true) {
        const ev = er.next() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        const event = ev orelse break;
        switch (event) {
            .end_of_input => break,
            .section_header => |h| {
                const name = if (d.case_insensitive_sections)
                    try std.ascii.allocLowerString(a, h.name)
                else
                    try a.dupe(u8, h.name);
                cur = if (h.subsection) |sub|
                    try std.fmt.allocPrint(a, "{s}.{s}", .{ name, sub })
                else
                    name;
            },
            .key_value => |kv| {
                const key = if (d.case_insensitive_keys)
                    try std.ascii.allocLowerString(a, kv.key)
                else
                    try a.dupe(u8, kv.key);
                const line = if (cur.len > 0)
                    try std.fmt.allocPrint(a, "{s}.{s}={s}", .{ cur, key, kv.value })
                else
                    try std.fmt.allocPrint(a, "{s}={s}", .{ key, kv.value });
                try out.append(a, line);
            },
            .comment => {},
        }
    }
    return true;
}

fn pairLt(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// Streaming arm invariant check for one input+dialect:
//   1. materialize (fixed reader, plus optionally 1-byte fragmenting reader)
//      must agree with ini.parse on both success/failure verdict and value.
//   2. EventReader event multiset must equal buffered parse with accumulate
//      policy (sorted comparison to accommodate legitimate ordering divergence
//      from positional events vs grouped buffered accumulate).
// Returns null when all invariants hold, a StreamFail on the first divergence.
fn fuzzStreaming(gpa: std.mem.Allocator, input: []const u8, d: Dialect, fragment: bool) !?StreamFail {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: ini.ParseOptions = .{ .dialect = d };

    // Reference: buffered parse of the full input.
    const v_buf = ini.parse(a, input, opts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Buffered failed. materialize calls parser.parse after buffering
            // the same bytes via the framer, so it must also fail.
            var r = std.Io.Reader.fixed(input);
            var er = ini.EventReader.fromReader(a, &r, opts);
            defer er.deinit();
            if (er.materialize(a)) |_| return .materialize_verdict else |me| {
                if (me == error.OutOfMemory) return error.OutOfMemory;
            }
            return null;
        },
    };

    // Check 1a: materialize via a fixed reader must return the same Value.
    {
        var r = std.Io.Reader.fixed(input);
        var er = ini.EventReader.fromReader(a, &r, opts);
        defer er.deinit();
        const v_mat = er.materialize(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .materialize_verdict,
        };
        if (!valueEql(v_buf, v_mat)) return .materialize_value;
    }

    // Check 1b: materialize via 1-byte fragmenting reader, exercising the
    // framer pull loop at maximum call count regardless of input size.
    if (fragment) {
        var frag_buf: [64]u8 = undefined;
        var cr = ChunkedReader.init(input, 1, &frag_buf);
        var er = ini.EventReader.fromReader(a, &cr.reader, opts);
        defer er.deinit();
        const v_frag = er.materialize(a) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .materialize_verdict,
        };
        if (!valueEql(v_buf, v_frag)) return .materialize_value;
    }

    // Check 2: EventReader event multiset vs buffered parse with accumulate
    // policy. Accumulate preserves every key/section occurrence in document
    // order, matching the per-event model. Sort both lists before comparing
    // because positional event order for interleaved duplicate keys can differ
    // from the buffered accumulate grouping order.
    {
        const acc_d = accumulatePolicy(d);
        const v_acc = ini.parse(a, input, .{ .dialect = acc_d }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null, // skip if accumulate parse also fails
        };

        var buf_pairs: std.ArrayList([]const u8) = .empty;
        try flatBuf(a, v_acc, acc_d, "", 0, &buf_pairs);
        std.mem.sort([]const u8, buf_pairs.items, {}, pairLt);

        var ev_pairs: std.ArrayList([]const u8) = .empty;
        const ev_ok = try flatEvents(a, input, d, &ev_pairs);
        if (!ev_ok) return .event_verdict;
        std.mem.sort([]const u8, ev_pairs.items, {}, pairLt);

        if (buf_pairs.items.len != ev_pairs.items.len) return .event_multiset;
        for (buf_pairs.items, ev_pairs.items) |b, e| {
            if (!std.mem.eql(u8, b, e)) return .event_multiset;
        }
    }

    return null;
}

// Bounded regression test: exercises the streaming arm under zig build test.
// Uses large inputs (>4096 bytes) so every iteration causes >1 framer pull,
// covering the cross-chunk resumption path that random-input fuzzing alone
// never reaches when max_input is capped at 4096 bytes.
// Fixed seed and 1000 iterations so it never hangs or OOMs.
test "streaming arm: materialize and EventReader equal buffered across chunk boundaries (1000 iters)" {
    const gpa = std.testing.allocator;
    const max_sz: usize = 16_384;
    const iterations: usize = 1000;

    var prng: std.Random.DefaultPrng = .init(0xdeadbeef_cafe1234);
    const rng = prng.random();

    const buf = try gpa.alloc(u8, max_sz);
    defer gpa.free(buf);

    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        // Alternate between straddle sizes and fully random large sizes.
        const len: usize = if (n % 2 == 0) rng.intRangeAtMost(usize, 4097, max_sz) else blk: {
            const bdry = [_]usize{ 4096, 8192, 12288 };
            const b = bdry[rng.uintLessThan(usize, bdry.len)];
            const off: i64 = @as(i64, @intCast(rng.uintLessThan(usize, 11))) - 5;
            const sz = @as(i64, @intCast(b)) + off;
            break :blk if (sz > 0 and @as(usize, @intCast(sz)) <= max_sz)
                @as(usize, @intCast(sz))
            else
                4096 + 1;
        };
        const input = buf[0..len];
        if (rng.uintLessThan(u8, 4) < 3) {
            rng.bytes(input);
        } else {
            generateBiased(rng, input);
        }

        for (all_dialects) |d| {
            if (try fuzzStreaming(gpa, input, d, n % 50 == 0)) |fail| {
                std.debug.print(
                    "streaming FAIL at iter {d} dialect={s} fail={t} input_len={d}\n",
                    .{ n, dialectName(d), fail, input.len },
                );
                return error.StreamingInvariantBroken;
            }
        }
    }
}

// Bounded regression test: exercises the round-trip invariant under zig build test.
// Fixed seed and iteration count (1000) so it never hangs or OOMs.
test "round-trip invariant (1000 iters, fixed seed)" {
    const gpa = std.testing.allocator;
    const max_input = 512;
    const iterations = 1000;

    var prng: std.Random.DefaultPrng = .init(0xcafe_babe_dead_beef);
    const rng = prng.random();

    const input_buf = try gpa.alloc(u8, max_input);
    defer gpa.free(input_buf);

    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        const len = rng.intRangeAtMost(usize, 0, max_input);
        const input = input_buf[0..len];

        if (rng.uintLessThan(u8, 4) < 3) {
            rng.bytes(input);
        } else {
            generateBiased(rng, input);
        }

        for (all_dialects) |d| {
            try fuzzNoCrash(gpa, input, d);
        }

        for (roundtrip_dialects) |d| {
            if (try fuzzRoundTrip(gpa, input, d)) |fail| {
                std.debug.print(
                    "round-trip FAIL at iter {d} dialect={s} fail={t} input_len={d}\ninput: ",
                    .{ n, dialectName(d), fail, input.len },
                );
                for (input) |b| {
                    if (b >= 0x20 and b < 0x7f) {
                        std.debug.print("{c}", .{b});
                    } else {
                        std.debug.print("\\x{x:0>2}", .{b});
                    }
                }
                std.debug.print("\n", .{});
                return error.RoundTripInvariantBroken;
            }
        }
    }
}

// Bounded regression test: exercises the sort_keys stability invariant under
// zig build test. Fixed seed and 1000 iterations so it never hangs or OOMs.
test "sort_keys stability invariant (1000 iters, fixed seed)" {
    const gpa = std.testing.allocator;
    const max_input = 512;
    const iterations = 1000;

    var prng: std.Random.DefaultPrng = .init(0x50a7_5eed_1234_5678);
    const rng = prng.random();

    const input_buf = try gpa.alloc(u8, max_input);
    defer gpa.free(input_buf);

    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        const len = rng.intRangeAtMost(usize, 0, max_input);
        const input = input_buf[0..len];

        if (rng.uintLessThan(u8, 4) < 3) {
            rng.bytes(input);
        } else {
            generateBiased(rng, input);
        }

        for (roundtrip_dialects) |d| {
            if (try fuzzSortStable(gpa, input, d)) |fail| {
                std.debug.print(
                    "sort_keys stability FAIL at iter {d} dialect={s} fail={t} input_len={d}\n",
                    .{ n, dialectName(d), fail, input.len },
                );
                return error.SortStabilityInvariantBroken;
            }
        }
    }
}
