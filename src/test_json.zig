const std = @import("std");
const json = @import("zig_json.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const input = "{\"key\": \"value\"}";
    const doc = try json.parseFromString(allocator, input);
    defer doc.deinit(allocator);

    doc.acquire();
    defer doc.release();

    const root = doc.root.v();
    std.debug.print("Parsed: {}\n", .{root});
}
