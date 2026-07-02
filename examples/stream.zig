//! Reader-backed streaming: EventReader and ValueStream.
//!
//! Demonstrates the two streaming entry points over in-program buffers,
//! using std.Io.Reader.fixed so no file I/O is needed:
//!
//!   (a) EventReader: walk a multi-section stream event by event, printing
//!       event kinds and payloads as they arrive.
//!   (b) ValueStream: iterate sections as complete Value trees with a
//!       per-section arena reset, bounding memory to one section at a time.

const std = @import("std");
const ini = @import("ini");

const multi_section_src =
    \\[alpha]
    \\host = alpha.example.com
    \\port = 8001
    \\
    \\[beta]
    \\host = beta.example.com
    \\port = 8002
    \\
    \\[gamma]
    \\host = gamma.example.com
    \\port = 8003
;

const value_stream_src =
    \\[svc-1]
    \\name = frontend
    \\weight = 10
    \\
    \\[svc-2]
    \\name = backend
    \\weight = 5
    \\
    \\[svc-3]
    \\name = worker
    \\weight = 2
;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try demoEventReader(gpa);
    try demoValueStream(gpa);
}

// (a) EventReader: walk event by event.
fn demoEventReader(gpa: std.mem.Allocator) !void {
    std.debug.print("--- EventReader: walk multi-section stream ---\n", .{});

    var r: std.Io.Reader = .fixed(multi_section_src);
    var er = ini.EventReader.fromReader(gpa, &r, .{});
    defer er.deinit();

    while (try er.next()) |ev| {
        switch (ev) {
            .end_of_input => {},
            .section_header => |h| std.debug.print(
                "section [{s}]  span=[{d},{d})\n",
                .{ h.name, h.span.start, h.span.end },
            ),
            .key_value => |kv| std.debug.print(
                "  {s} = {s}\n",
                .{ kv.key, kv.value },
            ),
            .comment => |c| std.debug.print(
                "  # {s}\n",
                .{c.text},
            ),
        }
    }
    std.debug.print("\n", .{});
}

// (b) ValueStream: compose one Value per section, resetting a per-section
//     arena between calls to bound working memory to one unit at a time.
fn demoValueStream(gpa: std.mem.Allocator) !void {
    std.debug.print("--- ValueStream: per-section arena reset ---\n", .{});

    var r: std.Io.Reader = .fixed(value_stream_src);
    var vs = ini.ValueStream.fromReader(gpa, &r, .{});
    defer vs.deinit();

    var item_arena: std.heap.ArenaAllocator = .init(gpa);
    defer item_arena.deinit();

    var i: usize = 0;
    while (try vs.next(item_arena.allocator())) |v| {
        // The root Value is a section; its first child entry is the section we want.
        if (v == .section and v.section.entries.len > 0) {
            const sec_entry = v.section.entries[0];
            if (sec_entry.value == .section) {
                const name = (try ini.getT([]const u8, item_arena.allocator(), sec_entry.value, "name", .{})) orelse "?";
                const weight = (try ini.getT(u32, item_arena.allocator(), sec_entry.value, "weight", .{})) orelse 0;
                std.debug.print("section[{d}]: [{s}]  name={s} weight={d}\n", .{ i, sec_entry.key, name, weight });
            }
        }
        i += 1;
        _ = item_arena.reset(.retain_capacity);
    }
}
