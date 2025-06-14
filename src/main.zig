const std = @import("std");
const builtin = @import("builtin");

fn trim(content: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\n");
    if (trimmed.len == 0) {
        return error.ZigVersionNotFound;
    }
    return trimmed;
}

fn findZigVersionFile(allocator: std.mem.Allocator, dir: []const u8) !std.fs.File {
    const zigversion_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, ".zigversion" });
    defer allocator.free(zigversion_path);
    return std.fs.openFileAbsolute(zigversion_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                const parent_dir = std.fs.path.dirname(dir);
                if (parent_dir) |pd| {
                    return findZigVersionFile(allocator, pd);
                }

                // Reached to the root. Cannot go any higher.
                // Return with the following error.
                std.log.err(".zigversion file not found", .{});
                std.process.abort();
            },
            else => return err,
        }
    };
}

fn readZigVersion(allocator: std.mem.Allocator) ![]u8 {
    // Read the .zigversion file
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    const file = try findZigVersionFile(allocator, cwd);
    defer file.close();

    // Read the entire file content
    const content = try file.readToEndAlloc(allocator, 1024);
    return content;
}

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

fn getZigDownloadUrl(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
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
    defer parsed.deinit();

    const version_obj = parsed.value.object.get(resolved_version);
    if (version_obj) |v| {
        const platform_obj = v.object.get(platform);
        if (platform_obj) |p| {
            const download_url = p.object.get("tarball") orelse return error.DownloadUrlNotFound;
            return allocator.dupe(u8, download_url.string);
        } else {
            return error.PlatformNotFound;
        }
    }

    // Version does not exist, so it is probably a pre-release version.
    return std.fmt.allocPrint(allocator, "https://ziglang.org/builds/zig-{s}-{s}.tar.xz", .{ platform, resolved_version });
}

pub fn getZigCompilerPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const platform = try getZigPlatform(allocator);
    defer allocator.free(platform);

    const home_path = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_path);

    const zig_use_path = try std.fs.path.join(allocator, &[_][]const u8{ home_path, ".zig-use" });
    defer allocator.free(zig_use_path);
    std.fs.makeDirAbsolute(zig_use_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const compiler_path = try std.fmt.allocPrint(allocator, ".zig-use/zig-{s}-{s}", .{ platform, version });
    defer allocator.free(compiler_path);

    const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ home_path, compiler_path });
    return absolute_path;
}

pub fn getZigCompilerTarPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const compiler_path = try getZigCompilerPath(allocator, version);
    defer allocator.free(compiler_path);

    return try std.fmt.allocPrint(allocator, "{s}.tar.xz", .{compiler_path});
}

pub fn downloadZigCompiler(allocator: std.mem.Allocator, download_url: []const u8, download_path: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(download_url);

    var hbuffer: [1024]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &hbuffer,
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    if (request.response.status == .ok) {
        const body = try request.reader().readAllAlloc(allocator, 500 * 1024 * 1024);
        defer allocator.free(body);

        const file = try std.fs.createFileAbsolute(download_path, .{});
        defer file.close();

        try file.writeAll(body);
        return;
    }

    std.log.err("could not find zig compiler to install", .{});
    std.log.err("invalid version specified in .zigversion file", .{});
    std.process.abort();
}

fn deleteFile(path: []const u8) !void {
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn deleteDirectory(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
}

fn checkIfZigCompilerIsInstalled(allocator: std.mem.Allocator, compiler_path: []const u8) !bool {
    const zig_exe_path = try std.fs.path.join(allocator, &[_][]const u8{ compiler_path, "zig" });
    std.fs.accessAbsolute(zig_exe_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };

    return true;
}

fn extractZigCompiler(allocator: std.mem.Allocator, tar_file_path: []const u8, extract_path: []const u8) !void {
    std.fs.makeDirAbsolute(extract_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    const args = &[_][]const u8{ "tar", "-xf", tar_file_path, "-C", extract_path, "--strip-components=1" };
    var child = std.process.Child.init(args, allocator);
    _ = try child.spawnAndWait();
}

fn passThroughCommand(allocator: std.mem.Allocator, compiler_path: []const u8) !void {
    const zig_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{compiler_path});
    defer allocator.free(zig_path);

    var cli_args = std.process.args();
    defer cli_args.deinit();

    // Skip the first argument as it is the cli name.
    _ = cli_args.next();

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append(zig_path);

    while (cli_args.next()) |arg| {
        try args.append(arg);
    }

    const args_slice = try args.toOwnedSlice();
    defer allocator.free(args_slice);

    var child = std.process.Child.init(args_slice, allocator);
    _ = try child.spawnAndWait();
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const zig_version = try readZigVersion(allocator);
    defer allocator.free(zig_version);

    const version = try trim(zig_version);
    if (std.mem.indexOf(u8, version, "\n")) |_| {
        std.log.err(".zigversion file should only contain a single version as its text content", .{});
        std.process.abort();
    }

    const tar_file_path = try getZigCompilerTarPath(allocator, version);
    defer allocator.free(tar_file_path);

    const compiler_path = try getZigCompilerPath(allocator, version);
    defer allocator.free(compiler_path);

    const is_installed = try checkIfZigCompilerIsInstalled(allocator, compiler_path);
    if (is_installed) {
        try passThroughCommand(allocator, compiler_path);
        return;
    }

    const download_url = try getZigDownloadUrl(allocator, version);
    defer allocator.free(download_url);

    // Cleanup just in case there is a leftover tar file or the compiler directory that may be present
    // in incorrect state.
    try deleteFile(tar_file_path);
    try deleteDirectory(compiler_path);

    std.debug.print("Downloading Zig ({s})...\n", .{version});
    try downloadZigCompiler(allocator, download_url, tar_file_path);
    defer {
        deleteFile(tar_file_path) catch |err| @panic(@errorName(err));
    }

    try extractZigCompiler(allocator, tar_file_path, compiler_path);
    try passThroughCommand(allocator, compiler_path);
}
