//! Differential harness: parse a fixture file with ini-zig and print
//! normalized output to stdout for comparison against reference tools.
//!
//! Usage: differential <dialect> <fixture_file>
//!   dialect: generic | gitconfig | systemd | windows
//!
//! Output format: sorted `path = escaped_value` lines, one per leaf.
//! Multi-value (list) keys are repeated once per element, preserving
//! insertion order within the same path. Special chars in values are
//! escaped: `\` -> `\\`, newline -> `\n`, tab -> `\t`.
//!
//! Prints nothing and exits 0 when called with --skip-check (for CI
//! portability on hosts without git or python3).

const std = @import("std");
const ini = @import("ini");

const Dialect = ini.Dialect;
const Value = ini.Value;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);

    if (args.len == 2 and std.mem.eql(u8, args[1], "--skip-check")) return;
    if (args.len != 3) {
        std.debug.print("usage: differential <dialect> <fixture_file>\n", .{});
        std.process.exit(1);
    }

    const dialect = dialectFrom(args[1]) orelse {
        std.debug.print("unknown dialect '{s}'; choose: generic gitconfig systemd windows\n", .{args[1]});
        std.process.exit(1);
    };

    const src = std.Io.Dir.readFileAlloc(.cwd(), init.io, args[2], a, .unlimited) catch |err| {
        std.debug.print("cannot read '{s}': {t}\n", .{ args[2], err });
        std.process.exit(1);
    };

    const val = ini.parse(a, src, .{ .dialect = dialect }) catch |err| {
        std.debug.print("parse error in '{s}': {t}\n", .{ args[2], err });
        std.process.exit(2);
    };

    var pairs: std.ArrayListUnmanaged(PathValue) = .empty;
    try flatten(a, &pairs, val, "");
    std.sort.insertion(PathValue, pairs.items, {}, pvLessThan);

    var aw: std.Io.Writer.Allocating = .init(a);
    for (pairs.items) |pv| {
        try aw.writer.print("{s} = ", .{pv.path});
        try writeEscaped(&aw.writer, pv.value);
        try aw.writer.writeByte('\n');
    }
    const out = aw.written();
    try std.Io.File.stdout().writeStreamingAll(init.io, out);
}

fn dialectFrom(name: []const u8) ?Dialect {
    if (std.mem.eql(u8, name, "generic")) return Dialect.generic;
    if (std.mem.eql(u8, name, "gitconfig")) return Dialect.gitconfig;
    if (std.mem.eql(u8, name, "systemd")) return Dialect.systemd;
    if (std.mem.eql(u8, name, "windows")) return Dialect.windows;
    return null;
}

const PathValue = struct {
    path: []const u8,
    value: []const u8,
};

fn pvLessThan(_: void, a: PathValue, b: PathValue) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

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

fn writeEscaped(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}
