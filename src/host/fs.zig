//! Filesystem, clock and log: identical on every backend, per
//! spec/host-contract.md. SDL, DRM and bare metal all get this for free;
//! only info/surface/present/wait are backend-specific.

const std = @import("std");
const host = @import("host.zig");

pub const HostError = error{
    NotFound,
    Permission,
    Io,
    Invalid,
    NoSpace,
    Busy,
    Unsupported,
    Exists,
};

pub fn errName(e: HostError) []const u8 {
    return switch (e) {
        error.NotFound => "not_found",
        error.Permission => "permission",
        error.Io => "io",
        error.Invalid => "invalid",
        error.NoSpace => "no_space",
        error.Busy => "busy",
        error.Unsupported => "unsupported",
        error.Exists => "exists",
    };
}

fn mapErr(e: anyerror) HostError {
    return switch (e) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.Permission,
        error.IsDir, error.NotDir => error.Invalid,
        error.NoSpaceLeft, error.StreamTooLong => error.NoSpace,
        error.FileBusy, error.WouldBlock => error.Busy,
        error.PathAlreadyExists => error.Exists,
        else => error.Io,
    };
}

/// Set once at startup from `std.process.Init.io` (main.zig) — the
/// application's entry point owns the `Io` choice, per Zig 0.16's Io
/// interface; nothing here should construct its own.
var g_io: std.Io = undefined;

pub fn setIo(io: std.Io) void {
    g_io = io;
}

pub const max_file_size = 16 * 1024 * 1024;

pub fn read(allocator: std.mem.Allocator, path: []const u8) HostError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(g_io, path, allocator, .limited(max_file_size)) catch |e| return mapErr(e);
}

pub fn write(path: []const u8, data: []const u8) HostError!void {
    const io = g_io;
    const dir_path = std.fs.path.dirname(path) orelse ".";
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |e| return mapErr(e);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&buf, "{s}.tmp-{d}", .{ path, std.Io.Clock.real.now(io).nanoseconds }) catch return error.Invalid;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = data }) catch |e| return mapErr(e);
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch |e| return mapErr(e);
}

pub const Entry = struct {
    name: []const u8,
    dir: bool,
    size: u64,
    mtime: i64,
};

pub fn list(allocator: std.mem.Allocator, path: []const u8) HostError![]Entry {
    const io = g_io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| return mapErr(e);
    defer dir.close(io);

    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(allocator);

    var it = dir.iterate();
    while (it.next(io) catch return error.Io) |e| {
        const stat = dir.statFile(io, e.name, .{}) catch |err| return mapErr(err);
        entries.append(allocator, .{
            .name = allocator.dupe(u8, e.name) catch return error.Io,
            .dir = e.kind == .directory,
            .size = stat.size,
            .mtime = stat.mtime.toSeconds(),
        }) catch return error.Io;
    }
    return entries.toOwnedSlice(allocator) catch return error.Io;
}

pub fn remove(path: []const u8) HostError!void {
    const io = g_io;
    std.Io.Dir.cwd().deleteTree(io, path) catch |e| return mapErr(e);
}

pub fn rename(from: []const u8, to: []const u8) HostError!void {
    const io = g_io;
    std.Io.Dir.cwd().renamePreserve(from, std.Io.Dir.cwd(), to, io) catch |e| return mapErr(e);
}

var start_ns: ?i96 = null;

pub fn nowMs() i64 {
    const io = g_io;
    const now = std.Io.Clock.awake.now(io);
    if (start_ns == null) start_ns = now.nanoseconds;
    return @intCast(@divTrunc(now.nanoseconds - start_ns.?, std.time.ns_per_ms));
}

pub fn clock() host.Clock {
    const io = g_io;
    const now = std.Io.Clock.real.now(io);
    return .{
        .unix_ms = now.toMilliseconds(),
        .utc_offset_min = 0,
    };
}

pub fn log(str: []const u8) void {
    std.debug.print("{s}\n", .{str});
}
