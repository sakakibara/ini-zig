//! Track source positions for tooling: IDE features, custom validators,
//! and rich error messages that point at the offending byte range.

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
        \\port = 99999
        \\
        \\[database]
        \\host = localhost
        \\port = 5432
    ;

    // spans is populated by parse using the arena allocator, so arena.deinit() frees it.
    var spans: ini.Spans = .empty;

    const v = try ini.parse(arena.allocator(), src, .{ .spans = &spans });
    _ = v;

    if (spans.get("server.port")) |span| {
        const raw = src[span.start..span.end];
        const port_val = std.fmt.parseInt(u32, raw, 10) catch 0;
        if (port_val > 65535) {
            // line/col are derived on demand from the byte offset and source.
            const lc = span.lineCol(src);
            std.debug.print("error at line {d} col {d}: port {d} out of [1..65535]\n", .{
                lc.line, lc.col, port_val,
            });
            std.debug.print("  source bytes [{d}..{d}]: \"{s}\"\n", .{
                span.start, span.end, raw,
            });
        }
    }

    std.debug.print("\nall tracked spans:\n", .{});
    var it = spans.iterator();
    while (it.next()) |entry| {
        const sp = entry.value_ptr.*;
        const lc = sp.lineCol(src);
        std.debug.print("  {s:<25} line {d:>2} col {d:>2}  bytes [{d}..{d}]\n", .{
            entry.key_ptr.*, lc.line, lc.col, sp.start, sp.end,
        });
    }
}
