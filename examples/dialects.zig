//! Parse the same input under five different dialect presets and show where
//! the results diverge.  Three divergence axes are visible on identical input:
//!   - subsection nesting: gitconfig interprets [remote "origin"] as section
//!     "remote" / subsection "origin"; all other presets treat the full string
//!     as a flat section name.
//!   - duplicate-key policy: gitconfig and systemd accumulate repeated keys
//!     into a list; generic, windows, and strict keep only the last value.
//!   - bare-key and separator rules: generic accepts ':' as a separator so
//!     "port : 9000" becomes key=port value=9000; gitconfig allows no-value
//!     bare keys so the same line is stored as a bare key named "port : 9000";
//!     systemd, windows, and strict accept neither, so they reject the input.

const std = @import("std");
const ini = @import("ini");

const src =
    \\; shared configuration
    \\[remote "origin"]
    \\url = git@github.com:org/repo.git
    \\tag = v1
    \\tag = v2
    \\port : 9000
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const presets = [_]struct {
        name: []const u8,
        d: ini.Dialect,
    }{
        .{ .name = "generic  ", .d = ini.Dialect.generic },
        .{ .name = "gitconfig", .d = ini.Dialect.gitconfig },
        .{ .name = "systemd  ", .d = ini.Dialect.systemd },
        .{ .name = "windows  ", .d = ini.Dialect.windows },
        .{ .name = "strict   ", .d = ini.Dialect.strict },
    };

    for (presets) |p| {
        std.debug.print("[{s}]\n", .{p.name});

        const v = ini.parse(arena.allocator(), src, .{ .dialect = p.d }) catch |err| {
            std.debug.print("  rejected: {t}\n\n", .{err});
            continue;
        };

        if (v == .section) printSection(1, v.section);
        std.debug.print("\n", .{});
    }
}

// Recursively print section entries with two spaces of indent per depth level.
// Uses '+=' for list items to distinguish repeated-key accumulation from
// last-wins overwrite (which shows only the surviving value).
fn printSection(depth: u8, sec: *ini.Section) void {
    const spaces = "                ";
    const ind_len = @min(@as(usize, depth) * 2, spaces.len);
    const ind = spaces[0..ind_len];
    for (sec.entries) |e| {
        switch (e.value) {
            .string => |s| std.debug.print("{s}{s} = \"{s}\"\n", .{ ind, e.key, s }),
            .list => |items| for (items) |item| {
                std.debug.print("{s}{s} += \"{s}\"\n", .{ ind, e.key, item });
            },
            .section => |sub| {
                std.debug.print("{s}[{s}]\n", .{ ind, e.key });
                printSection(depth + 1, sub);
            },
        }
    }
}
