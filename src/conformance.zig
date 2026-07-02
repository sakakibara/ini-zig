//! Conformance harness over the authored multi-dialect fixture corpus.
//!
//! Each dialect subdirectory under `tests/corpus/` contains `valid/` and
//! `invalid/` subdirectories. Every input file in `valid/` is paired with a
//! `.expected` sibling giving the normalized parse: sorted `path = value`
//! lines, one per leaf, lists repeated. Every input file in `invalid/` is
//! paired with a `.error` sibling naming the expected error tag (e.g.
//! `ExpectedAssignment`). The corpus root is injected by build.zig via
//! `b.addOptions` as `conformance_options`.
//!
//! Fixture counts are pinned constants so silent corpus drift (lost or extra
//! files) fails the suite rather than silently passing fewer checks.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const ini = @import("ini.zig");
const conformance_options = @import("conformance_options");

const Dialect = ini.Dialect;
const Value = ini.Value;

const max_fixture_bytes: usize = 1 << 16; // 64 KiB; all corpus files are small

const expected_generic_valid: usize = 9;
const expected_generic_invalid: usize = 1;
const expected_gitconfig_valid: usize = 10;
const expected_gitconfig_invalid: usize = 4;
const expected_systemd_valid: usize = 3;
const expected_systemd_invalid: usize = 2;
const expected_windows_valid: usize = 5;
const expected_windows_invalid: usize = 1;

fn openSubdir(io: Io, comptime sub: []const u8) !Io.Dir {
    const path = conformance_options.corpus_path ++ "/" ++ sub;
    return Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
}

fn readFile(io: Io, a: std.mem.Allocator, dir: Io.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(io, name, a, .limited(max_fixture_bytes)) catch |err| {
        std.debug.print("conformance: cannot read '{s}': {t}\n", .{ name, err });
        return err;
    };
}

const PathValue = struct {
    path: []const u8,
    value: []const u8,
};

fn pvLessThan(_: void, a: PathValue, b: PathValue) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Recursively flatten `val` into `out`, building dotted paths under `prefix`.
fn flatten(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(PathValue), val: Value, prefix: []const u8) !void {
    switch (val) {
        .section => |sec| {
            for (sec.entries) |entry| {
                const path = if (prefix.len == 0)
                    try a.dupe(u8, entry.key)
                else
                    try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, entry.key });
                try flatten(a, out, entry.value, path);
            }
        },
        .string => |s| try out.append(a, .{ .path = prefix, .value = s }),
        .list => |items| {
            for (items) |s| try out.append(a, .{ .path = prefix, .value = s });
        },
    }
}

/// Append a `path = escaped_value\n` line to `w`, escaping `\`, newline, tab.
fn writeLine(w: *std.Io.Writer, path: []const u8, value: []const u8) !void {
    try w.print("{s} = ", .{path});
    for (value) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('\n');
}

/// Normalize a parsed `Value` tree to sorted `path = escaped_value\n` lines.
fn normalize(a: std.mem.Allocator, w: *std.Io.Writer, val: Value) !void {
    var pairs: std.ArrayListUnmanaged(PathValue) = .empty;
    try flatten(a, &pairs, val, "");
    std.sort.insertion(PathValue, pairs.items, {}, pvLessThan);
    for (pairs.items) |pv| try writeLine(w, pv.path, pv.value);
}

/// Unescape `\\` -> `\`, `\n` -> newline, `\t` -> tab in an expected-file value string.
fn unescapeExpected(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const decoded: u8 = switch (s[i + 1]) {
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                else => { try out.append(a, s[i]); continue; },
            };
            try out.append(a, decoded);
            i += 1;
        } else {
            try out.append(a, s[i]);
        }
    }
    return out.toOwnedSlice(a);
}

/// Map an error tag name from a `.error` file to an `anyerror` value.
/// Returns null if the tag is not recognized.
fn errorFor(name: []const u8) ?anyerror {
    const n = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.eql(u8, n, "ExpectedAssignment")) return error.ExpectedAssignment;
    if (std.mem.eql(u8, n, "MalformedSectionHeader")) return error.MalformedSectionHeader;
    if (std.mem.eql(u8, n, "EmptyKey")) return error.EmptyKey;
    if (std.mem.eql(u8, n, "KeyBeforeSection")) return error.KeyBeforeSection;
    if (std.mem.eql(u8, n, "DuplicateKey")) return error.DuplicateKey;
    if (std.mem.eql(u8, n, "DuplicateSection")) return error.DuplicateSection;
    if (std.mem.eql(u8, n, "NestingTooDeep")) return error.NestingTooDeep;
    if (std.mem.eql(u8, n, "InvalidEscape")) return error.InvalidEscape;
    if (std.mem.eql(u8, n, "UnterminatedQuote")) return error.UnterminatedQuote;
    return null;
}

/// Walk `valid/` under `subdir`, parse each fixture with `dialect`, compare
/// normalized output against the sibling `.expected` file.
fn runValid(io: Io, comptime subdir: []const u8, dialect: Dialect, expected_count: usize) !void {
    var dir = try openSubdir(io, subdir);
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Skip companion files; process only the fixture inputs.
        if (std.mem.endsWith(u8, entry.name, ".expected")) continue;
        if (std.mem.endsWith(u8, entry.name, ".error")) continue;

        // Companion .expected file: same base name with .expected suffix.
        const dot = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse entry.name.len;
        const base = entry.name[0..dot];
        const expected_name = try std.fmt.allocPrint(testing.allocator, "{s}.expected", .{base});
        defer testing.allocator.free(expected_name);

        count += 1;

        const fixture_src = readFile(io, testing.allocator, dir, entry.name) catch |err| {
            std.debug.print("conformance: {s}: cannot read fixture: {t}\n", .{ entry.name, err });
            failures += 1;
            continue;
        };
        defer testing.allocator.free(fixture_src);

        const expected_src = readFile(io, testing.allocator, dir, expected_name) catch |err| {
            std.debug.print("conformance: {s}: cannot read .expected: {t}\n", .{ entry.name, err });
            failures += 1;
            continue;
        };
        defer testing.allocator.free(expected_src);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const val = ini.parse(a, fixture_src, .{ .dialect = dialect }) catch |err| {
            std.debug.print("conformance: {s}/{s}: unexpected parse error: {t}\n", .{ subdir, entry.name, err });
            failures += 1;
            continue;
        };

        // Produce normalized form of actual parse.
        var gw: std.Io.Writer.Allocating = .init(a);
        normalize(a, &gw.writer, val) catch {
            failures += 1;
            continue;
        };
        const got = gw.written();

        // Produce canonical form of expected file (re-escape after unescape).
        var ww: std.Io.Writer.Allocating = .init(a);
        var lines = std.mem.splitScalar(u8, expected_src, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            // Accept both "path = value" and "path =" (empty value).
            const path: []const u8, const raw_val: []const u8 = blk: {
                if (std.mem.indexOf(u8, trimmed, " = ")) |eq| {
                    break :blk .{ trimmed[0..eq], trimmed[eq + 3 ..] };
                } else if (std.mem.endsWith(u8, trimmed, " =")) {
                    break :blk .{ trimmed[0 .. trimmed.len - 2], "" };
                } else {
                    std.debug.print("conformance: {s}: malformed expected line: '{s}'\n", .{ expected_name, trimmed });
                    failures += 1;
                    break;
                }
            };
            const uval = try unescapeExpected(a, raw_val);
            try writeLine(&ww.writer, path, uval);
        }
        const want = ww.written();

        if (!std.mem.eql(u8, got, want)) {
            std.debug.print(
                "conformance: {s}/{s}: mismatch\n--- got ---\n{s}--- want ---\n{s}\n",
                .{ subdir, entry.name, got, want },
            );
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_count, count);
}

/// Walk `invalid/` under `subdir`, assert each fixture parses to the error
/// named in its sibling `.error` file.
fn runInvalid(io: Io, comptime subdir: []const u8, dialect: Dialect, expected_count: usize) !void {
    var dir = try openSubdir(io, subdir);
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".expected")) continue;
        if (std.mem.endsWith(u8, entry.name, ".error")) continue;

        const dot = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse entry.name.len;
        const base = entry.name[0..dot];
        const error_name = try std.fmt.allocPrint(testing.allocator, "{s}.error", .{base});
        defer testing.allocator.free(error_name);

        count += 1;

        const fixture_src = readFile(io, testing.allocator, dir, entry.name) catch |err| {
            std.debug.print("conformance: {s}: cannot read fixture: {t}\n", .{ entry.name, err });
            failures += 1;
            continue;
        };
        defer testing.allocator.free(fixture_src);

        const error_src = readFile(io, testing.allocator, dir, error_name) catch |err| {
            std.debug.print("conformance: {s}: cannot read .error: {t}\n", .{ entry.name, err });
            failures += 1;
            continue;
        };
        defer testing.allocator.free(error_src);

        const want_err = errorFor(error_src) orelse {
            std.debug.print("conformance: {s}: unknown error tag\n", .{error_name});
            failures += 1;
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const result = ini.parse(arena.allocator(), fixture_src, .{ .dialect = dialect });
        if (result) |_| {
            std.debug.print(
                "conformance: {s}/{s}: expected {t} but parse succeeded\n",
                .{ subdir, entry.name, want_err },
            );
            failures += 1;
        } else |got_err| {
            if (got_err != want_err) {
                std.debug.print(
                    "conformance: {s}/{s}: expected {t}, got {t}\n",
                    .{ subdir, entry.name, want_err, got_err },
                );
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(expected_count, count);
}

test "generic valid" {
    try runValid(testing.io, "generic/valid", Dialect.generic, expected_generic_valid);
}

test "generic invalid" {
    try runInvalid(testing.io, "generic/invalid", Dialect.generic, expected_generic_invalid);
}

test "gitconfig valid" {
    try runValid(testing.io, "gitconfig/valid", Dialect.gitconfig, expected_gitconfig_valid);
}

test "gitconfig invalid" {
    try runInvalid(testing.io, "gitconfig/invalid", Dialect.gitconfig, expected_gitconfig_invalid);
}

test "systemd valid" {
    try runValid(testing.io, "systemd/valid", Dialect.systemd, expected_systemd_valid);
}

test "systemd invalid" {
    try runInvalid(testing.io, "systemd/invalid", Dialect.systemd, expected_systemd_invalid);
}

test "windows valid" {
    try runValid(testing.io, "windows/valid", Dialect.windows, expected_windows_valid);
}

test "windows invalid" {
    try runInvalid(testing.io, "windows/invalid", Dialect.windows, expected_windows_invalid);
}
