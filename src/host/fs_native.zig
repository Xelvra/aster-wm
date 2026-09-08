//! Filesystem and log: identical on every backend, per spec/host-contract.md.
//! SDL, DRM and bare metal all get these for free. `realClock()` below is a
//! shared *helper* a backend's own `clockFn` can call — whether a backend
//! has a real-time clock at all is a per-backend decision (host.zig's
//! `Backend.clockFn`, alongside info/surface/present/wait), not something
//! this file can decide on every backend's behalf (see B15 in
//! troubleshooting.md).

const std = @import("std");
const host = @import("host.zig");
const c = @cImport({
    @cInclude("time.h");
});

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

pub fn errName(e: HostError) [:0]const u8 {
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
    std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch |e| {
        // The write itself succeeded; only the atomic swap failed (e.g. the
        // destination directory vanished between createDirPath and here).
        // Leaving `.tmp-<ns>` behind would be a stray file next to the
        // target forever — clean it up before surfacing the error.
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return mapErr(e);
    };
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
    // Frees each already-duplicated `name` too, not just the array's own
    // backing storage — a failure partway through the loop below (a
    // statFile error, an OOM append) would otherwise leak every entry
    // duped before it.
    errdefer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

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

/// Recursively deletes `path` (spec/host-contract.md's Filesystem section)
/// and returns `not_found` if it doesn't exist. `deleteTree` on its own
/// tolerates a missing top-level path (treats "already gone" as success,
/// `rm -rf`-style), so existence is checked explicitly first to give
/// `not_found` its own, distinguishable answer instead of always `true`.
pub fn remove(path: []const u8) HostError!void {
    const io = g_io;
    std.Io.Dir.cwd().access(io, path, .{}) catch |e| return mapErr(e);
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

/// The actual wall-clock read, shared by any backend whose `clockFn`
/// reports it has one (SDL, DRM — anything running under an OS). A backend
/// with no real-time clock (bare metal with no RTC) has its own `clockFn`
/// that returns null instead of calling this.
///
/// The UTC offset comes from libc's `localtime_r`/`tm_gmtoff` (a GNU/BSD
/// extension present on every libc this project links against), not
/// std.Io's Zig-side clock — Zig 0.16's Io redesign (see B1 in
/// troubleshooting.md) has no timezone-aware API of its own, and getting
/// the offset wrong silently (rather than not having one) is worse.
pub fn realClock() host.Clock {
    const io = g_io;
    const now = std.Io.Clock.real.now(io);
    const unix_ms = now.toMilliseconds();
    const secs: c.time_t = @intCast(@divFloor(unix_ms, 1000));
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&secs, &tm);
    return .{
        .unix_ms = unix_ms,
        .utc_offset_min = @intCast(@divTrunc(tm.tm_gmtoff, 60)),
    };
}

pub fn log(str: []const u8) void {
    std.debug.print("{s}\n", .{str});
}
