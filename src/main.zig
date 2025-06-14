const std = @import("std");
const builtin = @import("builtin");

fn readZigVersion(allocator: std.mem.Allocator) ![]u8 {
    // Read the .zigversion file
    const file = try std.fs.cwd().openFile(".zigversion", .{});
    defer file.close();

    // Read the entire file content
    const content = try file.readToEndAlloc(allocator, 1024);
    return content;
}

const ZigCompiler = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    version: []const u8,

    fn deinit(self: *ZigCompiler) void {
        self.allocator.free(self.url);
        self.allocator.free(self.version);

        self.* = undefined;
    }
};

fn getZigPlatform(allocator: std.mem.Allocator) ![]u8 {
    const os = builtin.os.tag;
    const os_name = switch (os) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => unreachable,
    };

    const arch = builtin.cpu.arch;
    const arch_name = switch (arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => unreachable,
    };

    const platform = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch_name, os_name });
    return platform;
}

fn resolveZigCompiler(allocator: std.mem.Allocator, version: []u8) !ZigCompiler {
    const platform = try getZigPlatform(allocator);
    defer allocator.free(platform);

    const resolved_version = if (version.len > 0) version else "master";

    // Download the index.json from ziglang.org
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://ziglang.org/download/index.json");

    var hbuffer: [1024]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &hbuffer,
    });
    defer request.deinit();
    try request.send();
    try request.finish();
    try request.wait();

    const body = try request.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    // Parse the JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const version_obj = parsed.value.object.get(resolved_version);
    if (version_obj) |v| {
        const final_version = if (v.object.get("version")) |ver| ver.string else resolved_version;
        const platform_obj = v.object.get(platform);
        if (platform_obj) |p| {
            const download_url = p.object.get("tarball") orelse return error.DownloadUrlNotFound;
            return .{
                .allocator = allocator,
                .url = try allocator.dupe(u8, download_url.string),
                .version = try allocator.dupe(u8, final_version),
            };
        } else {
            return error.PlatformNotFound;
        }
    }

    // Version does not exist, so it is probably a pre-release version.
    const url = try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/zig-{s}-{s}.tar.xz", .{ platform, resolved_version });
    return .{
        .allocator = allocator,
        .url = try allocator.dupe(u8, url),
        .version = try allocator.dupe(u8, version),
    };
}

pub fn downloadZigCompiler(allocator: std.mem.Allocator, zig_compiler: ZigCompiler) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(zig_compiler.url);

    var hbuffer: [1024]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &hbuffer,
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    const body = try request.reader().readAllAlloc(allocator, 500 * 1024 * 1024);
    defer allocator.free(body);

    const platform = try getZigPlatform(allocator);
    defer allocator.free(platform);

    const compiler_name = try std.fmt.allocPrint(allocator, "zig-{s}-{s}", .{ platform, zig_compiler.version });
    defer allocator.free(compiler_name);

    const file_path = try std.fmt.allocPrint(allocator, "zig-out/{s}.tar.xz", .{compiler_name});
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(body);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const zig_version = try readZigVersion(allocator);
    defer allocator.free(zig_version);

    var zig_download = try resolveZigCompiler(allocator, zig_version);
    defer zig_download.deinit();

    std.debug.print("{s}\n", .{zig_download.url});
    std.debug.print("{s}\n", .{zig_download.version});

    try downloadZigCompiler(allocator, zig_download);
}
