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

fn resolveZigCompiler(allocator: std.mem.Allocator, version: []const u8) !ZigCompiler {
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

pub fn getZigCompilerPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const platform = try getZigPlatform(allocator);
    defer allocator.free(platform);

    const file_path = try std.fmt.allocPrint(allocator, "zig-out/zig-{s}-{s}", .{ platform, version });
    defer allocator.free(file_path);

    // Join the file path with the current working directory
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const joined_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd_path, file_path });
    return joined_path;
}

pub fn getZigCompilerTarPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const compiler_path = try getZigCompilerPath(allocator, version);
    defer allocator.free(compiler_path);

    return try std.fmt.allocPrint(allocator, "{s}.tar.xz", .{compiler_path});
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

    const file_path = try getZigCompilerTarPath(allocator, zig_compiler.version);
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(body);
}

fn cleanupTarFile(allocator: std.mem.Allocator, version: []const u8) !void {
    const file_path = try getZigCompilerTarPath(allocator, version);
    defer allocator.free(file_path);

    std.fs.deleteFileAbsolute(file_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn checkIfZigCompilerIsInstalled(allocator: std.mem.Allocator, version: []const u8) !bool {
    const path = try getZigCompilerPath(allocator, version);
    defer allocator.free(path);

    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };

    return true;
}

fn extractZigCompiler(allocator: std.mem.Allocator, version: []const u8) !void {
    const file_path = try getZigCompilerTarPath(allocator, version);
    defer allocator.free(file_path);

    const compiler_path = try getZigCompilerPath(allocator, version);
    defer allocator.free(compiler_path);

    std.fs.cwd().makeDir(compiler_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const args = &[_][]const u8{ "tar", "-xf", file_path, "-C", compiler_path, "--strip-components=1" };
    return std.process.execv(allocator, args);
}

fn passThroughCommand(allocator: std.mem.Allocator, version: []const u8) !void {
    const compiler_path = try getZigCompilerPath(allocator, version);
    defer allocator.free(compiler_path);

    const zig_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{compiler_path});
    defer allocator.free(zig_path);

    const args = &[_][]const u8{ zig_path, "version" };
    return std.process.execv(allocator, args);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const zig_version = try readZigVersion(allocator);
    defer allocator.free(zig_version);

    var compiler = try resolveZigCompiler(allocator, zig_version);
    defer compiler.deinit();

    // Cleanup just in case there is a leftover tar file from a previous run.
    try cleanupTarFile(allocator, compiler.version);

    const is_installed = try checkIfZigCompilerIsInstalled(allocator, compiler.version);
    if (is_installed) {
        try passThroughCommand(allocator, compiler.version);
        return;
    }

    std.debug.print("Downloading Zig ({s})...\n", .{compiler.version});
    try downloadZigCompiler(allocator, compiler);
    defer cleanupTarFile(allocator, compiler.version) catch |err| @panic(@errorName(err));

    try extractZigCompiler(allocator, compiler.version);
}
