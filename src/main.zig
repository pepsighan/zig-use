const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Read the .zigversion file
    const file = try std.fs.cwd().openFile(".zigversion", .{});
    defer file.close();

    // Read the entire file content
    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    std.debug.print("{s}\n", .{content});
}
