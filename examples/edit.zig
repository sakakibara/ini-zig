//! Edit an INI document while preserving comments, whitespace, and key
//! ordering. The lossless document model emits byte-identical output for
//! unmodified input, and minimal-diff output when modified.

const std = @import("std");
const ini = @import("ini");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    defer arena.deinit();

    const src =
        \\# Service configuration -- hand-edited, preserve formatting!
        \\
        \\[server]
        \\host = localhost
        \\port = 8080
        \\tls = false
        \\
        \\[cache]
        \\ttl = 300
        \\
    ;

    // gitconfig strips inline comments, so setTrailingComment round-trips here.
    var doc = try ini.Document.parse(arena.allocator(), src, .{ .dialect = ini.Dialect.gitconfig });

    const port = (try doc.getT(u16, "server.port")) orelse 0;
    std.debug.print("before: server.port = {d}\n", .{port});

    try doc.set("server.port", @as(u16, 9443));
    try doc.set("server.tls", true);

    // Add a comment before a key (indentation is mirrored automatically).
    try doc.addCommentBefore("cache.ttl", "seconds until entries expire");

    try doc.setTrailingComment("server.host", "bind address");

    // Emit: comments and ordering are preserved; only touched lines change.
    var aw: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer aw.deinit();
    try doc.emit(&aw.writer);

    std.debug.print("--- after edits ---\n{s}", .{aw.written()});
}
