//! Parse an INI document into a dynamic Value tree and read fields by
//! dotted path. The simplest entry point.

const std = @import("std");
const ini = @import("ini");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\[server]
        \\host = 127.0.0.1
        \\port = 8080
        \\tls = false
        \\
        \\[database]
        \\host = localhost
        \\port = 5432
        \\name = appdb
    ;

    const v = try ini.parse(arena.allocator(), src, .{});

    const host = v.section.get("server.host").?.string;
    std.debug.print("server.host = {s}\n", .{host});

    // getT decodes directly to a Zig type; null on missing or wrong type.
    const port = try ini.getT(u16, arena.allocator(), v, "server.port", .{});
    std.debug.print("server.port = {?d}\n", .{port});

    const tls = try ini.getT(bool, arena.allocator(), v, "server.tls", .{});
    std.debug.print("server.tls  = {?}\n", .{tls});

    std.debug.print("database.name = {s}\n", .{
        v.section.get("database.name").?.string,
    });
}
