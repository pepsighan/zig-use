const std = @import("std");

fn readZigVersion(allocator: std.mem.Allocator) ![]u8 {
    // Read the .zigversion file
    const file = try std.fs.cwd().openFile(".zigversion", .{});
    defer file.close();

    // Read the entire file content
    const content = try file.readToEndAlloc(allocator, 1024);
    return content;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const zig_version = try readZigVersion(allocator);
    defer allocator.free(zig_version);

    std.debug.print("{s}\n", .{zig_version});
}
