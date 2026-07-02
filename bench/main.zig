//! Microbenchmarks for the ini library.
//!
//! Methodology:
//! - Each benchmark runs `inner_iters` operations to amortize timer
//!   resolution; the total elapsed time divided by `inner_iters` is one sample.
//! - `samples` such samples are collected; the reported numbers are the
//!   min, p50, p99, max, and standard deviation across samples.
//! - One untimed warmup sample runs first to populate caches.
//! - Arenas are reset between iterations so allocator behavior reflects
//!   realistic parse-and-discard usage.
//! - The monotonic `awake` clock is used for timing.
//! - Dead-code elimination is suppressed via `std.mem.doNotOptimizeAway`.
//!
//! Caveats:
//! - These are microbenchmarks on synthetic-but-representative inputs.
//!   Real workloads vary; treat absolute numbers as order-of-magnitude only.
//! - CPU frequency scaling and thermal throttling can shift numbers by 2x.
//!   Compare runs on the same machine at the same thermal state.
//! - Numbers are wall-clock, single-threaded.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ini = @import("ini");

const fixtures = @import("fixtures.zig");

const Bench = struct {
    name: []const u8,
    fixture: []const u8,
    inner_iters: usize,
    samples: usize = 11,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    try printHeader(w);

    const benches = [_]Bench{
        .{ .name = "small  (~495 B)",    .fixture = fixtures.small,  .inner_iters = 50_000 },
        .{ .name = "medium (~40 KB)",    .fixture = fixtures.medium, .inner_iters = 500 },
        .{ .name = "large  (~230 KB)",   .fixture = fixtures.large,  .inner_iters = 50 },
    };

    for (benches) |b| {
        try runBench(w, gpa, io, b);
        try w.writeByte('\n');
    }

    try benchValueStreamBounded(w, gpa, io);

    try printFooter(w);
    try w.flush();
}

fn printHeader(w: *Io.Writer) !void {
    try w.print(
        \\ini microbenchmarks
        \\  zig:        {s}
        \\  optimize:   {t}
        \\  target:     {t}-{t}-{t}
        \\  cpu:        {s}
        \\
        \\
    , .{
        builtin.zig_version_string,
        builtin.mode,
        builtin.cpu.arch,
        builtin.os.tag,
        builtin.abi,
        builtin.cpu.model.name,
    });
}

fn printFooter(w: *Io.Writer) !void {
    try w.writeAll(
        \\methodology: each row is `samples` repetitions of `inner_iters` ops;
        \\reported numbers (min/p50/p99/max) are per-op latency across samples.
        \\throughput is computed from the median sample.
        \\
    );
}

fn runBench(w: *Io.Writer, gpa: std.mem.Allocator, io: Io, b: Bench) !void {
    try w.print("== {s}  ({d} bytes, {d} samples x {d} iters) ==\n", .{
        b.name, b.fixture.len, b.samples, b.inner_iters,
    });

    try sampleAndReport(w, gpa, io, b, "parse  ", benchParse);
    try sampleAndReport(w, gpa, io, b, "encode ", benchEncode);
}

const SampleFn = fn (gpa: std.mem.Allocator, io: Io, fixture: []const u8, iters: usize) anyerror!u64;

fn sampleAndReport(
    w: *Io.Writer,
    gpa: std.mem.Allocator,
    io: Io,
    b: Bench,
    label: []const u8,
    sample: SampleFn,
) !void {
    _ = try sample(gpa, io, b.fixture, b.inner_iters);

    const samples = try gpa.alloc(u64, b.samples);
    defer gpa.free(samples);

    for (samples) |*s| {
        s.* = try sample(gpa, io, b.fixture, b.inner_iters);
    }

    const stats = computeStats(samples, b.inner_iters);
    try w.print(
        "  {s}  min {d:>9} ns  p50 {d:>9} ns  p99 {d:>9} ns  max {d:>9} ns  stddev {d:>7.0} ns  ({d:>6.1} MB/s)\n",
        .{
            label,
            stats.min_per_op,
            stats.p50_per_op,
            stats.p99_per_op,
            stats.max_per_op,
            stats.stddev,
            mbPerSec(b.fixture.len, stats.p50_per_op),
        },
    );
}

const Stats = struct {
    min_per_op: u64,
    p50_per_op: u64,
    p99_per_op: u64,
    max_per_op: u64,
    stddev: f64,
};

fn computeStats(total_ns_samples: []u64, inner_iters: usize) Stats {
    for (total_ns_samples) |*s| s.* /= inner_iters;
    std.sort.heap(u64, total_ns_samples, {}, std.sort.asc(u64));

    const n = total_ns_samples.len;
    const min = total_ns_samples[0];
    const max = total_ns_samples[n - 1];
    const p50 = total_ns_samples[n / 2];
    const p99_idx = (n * 99 + 99) / 100;
    const p99 = total_ns_samples[@min(p99_idx, n - 1)];

    var sum: f64 = 0;
    for (total_ns_samples) |x| sum += @floatFromInt(x);
    const mean = sum / @as(f64, @floatFromInt(n));
    var sq_diff_sum: f64 = 0;
    for (total_ns_samples) |x| {
        const d = @as(f64, @floatFromInt(x)) - mean;
        sq_diff_sum += d * d;
    }
    const stddev = std.math.sqrt(sq_diff_sum / @as(f64, @floatFromInt(n)));

    return .{ .min_per_op = min, .p50_per_op = p50, .p99_per_op = p99, .max_per_op = max, .stddev = stddev };
}

fn mbPerSec(bytes: usize, per_op_ns: u64) f64 {
    if (per_op_ns == 0) return 0;
    const bytes_per_op_f: f64 = @floatFromInt(bytes);
    const ns_f: f64 = @floatFromInt(per_op_ns);
    return bytes_per_op_f * 1_000.0 / ns_f / 1.048576;
}

fn benchParse(gpa: std.mem.Allocator, io: Io, fixture: []const u8, iters: usize) !u64 {
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    var sink: usize = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const v = try ini.parse(arena.allocator(), fixture, .{});
        if (v == .section) sink +%= v.section.entries.len;
    }
    std.mem.doNotOptimizeAway(&sink);
    return @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));
}

fn benchEncode(gpa: std.mem.Allocator, io: Io, fixture: []const u8, iters: usize) !u64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try ini.parse(arena.allocator(), fixture, .{});

    const t0 = Io.Clock.Timestamp.now(io, .awake);
    var sink: usize = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        ini.encode(&aw.writer, v, .{}) catch {};
        sink +%= aw.writer.end;
    }
    std.mem.doNotOptimizeAway(&sink);
    return @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));
}

/// Bounded-memory streaming bench. Builds a large synthetic INI stream of
/// 10,000 sections (each ~50 bytes), then streams it via EventReader,
/// checking that the internal buffer stays proportional to one section,
/// never the whole stream.
fn benchValueStreamBounded(w: *Io.Writer, gpa: std.mem.Allocator, io: Io) !void {
    const n_sections = 10_000;

    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    for (0..n_sections) |idx| {
        try buf.writer.print("[section-{d}]\nname = entry-{d}\nseq = {d}\n", .{ idx, idx, idx });
    }
    const stream_src = buf.written();
    const stream_bytes = stream_src.len;

    const one_elem_approx: usize = stream_bytes / n_sections + 8;

    const samples_count = 11;
    const sample_buf = try gpa.alloc(u64, samples_count);
    defer gpa.free(sample_buf);
    var peak_cap: usize = 0;

    // One untimed warmup pass.
    {
        var r: std.Io.Reader = .fixed(stream_src);
        var er = ini.EventReader.fromReader(gpa, &r, .{});
        defer er.deinit();
        while (try er.next()) |ev| {
            std.mem.doNotOptimizeAway(&ev);
        }
    }

    for (sample_buf) |*s| {
        var r: std.Io.Reader = .fixed(stream_src);
        var er = ini.EventReader.fromReader(gpa, &r, .{});
        defer er.deinit();

        const t0 = Io.Clock.Timestamp.now(io, .awake);
        var count: usize = 0;
        while (try er.next()) |ev| {
            std.mem.doNotOptimizeAway(&ev);
            count += 1;
        }
        s.* = @intCast(@max(t0.untilNow(io).raw.toNanoseconds(), 0));

        const cap = er.bufCapacity();
        if (cap > peak_cap) peak_cap = cap;
    }

    const stats = computeStats(sample_buf, 1);
    try w.print(
        "\n== EventReader bounded-memory  ({d} sections, {d} bytes) ==\n",
        .{ n_sections, stream_bytes },
    );
    try w.print(
        "  stream   min {d:>9} ns  p50 {d:>9} ns  p99 {d:>9} ns  max {d:>9} ns  stddev {d:>7.0} ns  ({d:>6.1} MB/s)\n",
        .{
            stats.min_per_op,
            stats.p50_per_op,
            stats.p99_per_op,
            stats.max_per_op,
            stats.stddev,
            mbPerSec(stream_bytes, stats.p50_per_op),
        },
    );

    // Peak bufCapacity must stay proportional to one section plus a pull chunk.
    // A cap near the whole stream size (500+ KB) indicates the bounded guarantee regressed.
    const cap_limit = 64 * 1024;
    if (peak_cap > cap_limit) {
        try w.print(
            "BOUNDED-MEMORY FAIL: peak bufCapacity {d} B exceeds limit {d} B (one_elem_approx={d} B)\n",
            .{ peak_cap, cap_limit, one_elem_approx },
        );
        try w.flush();
        std.process.exit(1);
    }

    try w.print(
        "  bounded-memory: peak bufCapacity = {d} B  (one_elem_approx = {d} B, n_sections = {d})\n",
        .{ peak_cap, one_elem_approx, n_sections },
    );
}
