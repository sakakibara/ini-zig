//! Decode an INI document directly into a Zig struct via comptime reflection.
//!
//! Field defaults satisfy missing-field cases. Optional fields become null
//! when absent. Unknown INI keys cause error.UnknownField unless
//! ParseOptions{ .ignore_unknown_fields = true } is passed.

const std = @import("std");
const ini = @import("ini");

const LogLevel = enum { debug, info, warn, err };

const Server = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    tls: bool = false,
};

const Config = struct {
    server: Server,
    log_level: LogLevel = .info,
    app_name: []const u8 = "app",
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\app_name = my-service
        \\log_level = warn
        \\
        \\[server]
        \\host = 0.0.0.0
        \\port = 9000
        \\tls = true
    ;

    const cfg = try ini.parseInto(Config, arena.allocator(), src, .{ .ignore_unknown_fields = true });

    std.debug.print("app_name:  {s}\n", .{cfg.app_name});
    std.debug.print("log_level: {s}\n", .{@tagName(cfg.log_level)});
    std.debug.print("host:      {s}\n", .{cfg.server.host});
    std.debug.print("port:      {d}\n", .{cfg.server.port});
    std.debug.print("tls:       {}\n", .{cfg.server.tls});
}
