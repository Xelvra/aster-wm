//! fs.zig's wasm implementation: the same read/write/list/remove/rename/
//! log/nowMs/realClock surface as fs_native.zig, backed by JS imports
//! instead of a real OS filesystem — wasm32-freestanding has no
//! std.Io.Dir.cwd() to call. The JS glue (src/backends/wasm/glue.js)
//! backs these with the browser's own localStorage, keyed by path.
//!
//! Two-phase protocols (js_fs_list_count/js_fs_list_entry, and read's
//! retry-on-too-small) exist because a wasm import can only pass and
//! return numbers — there's no way to hand JS a growable Zig buffer or
//! get a variable-length answer back in one call.

const std = @import("std");

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

// setIo exists only so fs.zig's dispatcher can re-export one `setIo`
// name regardless of target; main_wasm.zig never calls it (there's no
// std.Io on this backend to hand over).
pub fn setIo(_: anytype) void {}

pub const max_file_size = 16 * 1024 * 1024;

extern "aster" fn js_fs_read(path_ptr: [*]const u8, path_len: usize, out_ptr: [*]u8, out_cap: usize) i32;
extern "aster" fn js_fs_write(path_ptr: [*]const u8, path_len: usize, data_ptr: [*]const u8, data_len: usize) i32;
extern "aster" fn js_fs_list_count(path_ptr: [*]const u8, path_len: usize) i32;
extern "aster" fn js_fs_list_entry(
    path_ptr: [*]const u8,
    path_len: usize,
    index: usize,
    name_out: [*]u8,
    name_cap: usize,
    is_dir_out: *i32,
    size_out: *i64,
    mtime_out: *i64,
) i32;
extern "aster" fn js_fs_remove(path_ptr: [*]const u8, path_len: usize) i32;
extern "aster" fn js_fs_rename(from_ptr: [*]const u8, from_len: usize, to_ptr: [*]const u8, to_len: usize) i32;
extern "aster" fn js_log(ptr: [*]const u8, len: usize) void;
extern "aster" fn js_now_ms() f64;
extern "aster" fn js_wall_clock_ms() f64;
extern "aster" fn js_utc_offset_min() i32;

/// read()'s buffer starts here and doubles on a "too small" reply, same
/// growth shape as fs_native.read's allocator-backed version, capped at
/// max_file_size (spec/host-contract.md doesn't promise more).
pub fn read(allocator: std.mem.Allocator, path: []const u8) HostError![]u8 {
    var cap: usize = 4096;
    while (cap <= max_file_size) : (cap *= 2) {
        const buf = allocator.alloc(u8, cap) catch return error.Io;
        const n = js_fs_read(path.ptr, path.len, buf.ptr, buf.len);
        if (n == -1) {
            allocator.free(buf);
            return error.NotFound;
        }
        if (n == -2) {
            allocator.free(buf);
            continue; // buffer too small, retry bigger
        }
        if (n < 0) {
            allocator.free(buf);
            return error.Io;
        }
        const len: usize = @intCast(n);
        return allocator.realloc(buf, len) catch buf[0..len];
    }
    return error.NoSpace;
}

pub fn write(path: []const u8, data: []const u8) HostError!void {
    const r = js_fs_write(path.ptr, path.len, data.ptr, data.len);
    if (r == 0) return;
    return switch (r) {
        -1 => error.Permission,
        -2 => error.NoSpace,
        else => error.Io,
    };
}

pub const Entry = struct {
    name: []const u8,
    dir: bool,
    size: u64,
    mtime: i64,
};

pub fn list(allocator: std.mem.Allocator, path: []const u8) HostError![]Entry {
    const count = js_fs_list_count(path.ptr, path.len);
    if (count == -1) return error.NotFound;
    if (count < 0) return error.Io;

    var entries = std.ArrayList(Entry).empty;
    errdefer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var name_buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        var is_dir: i32 = 0;
        var size: i64 = 0;
        var mtime: i64 = 0;
        const n = js_fs_list_entry(path.ptr, path.len, i, &name_buf, name_buf.len, &is_dir, &size, &mtime);
        if (n < 0) return error.Io;
        entries.append(allocator, .{
            .name = allocator.dupe(u8, name_buf[0..@intCast(n)]) catch return error.Io,
            .dir = is_dir != 0,
            .size = @intCast(size),
            .mtime = mtime,
        }) catch return error.Io;
    }
    return entries.toOwnedSlice(allocator) catch return error.Io;
}

pub fn remove(path: []const u8) HostError!void {
    const r = js_fs_remove(path.ptr, path.len);
    if (r == 0) return;
    return error.NotFound;
}

pub fn rename(from: []const u8, to: []const u8) HostError!void {
    const r = js_fs_rename(from.ptr, from.len, to.ptr, to.len);
    return switch (r) {
        0 => {},
        -1 => error.NotFound,
        -2 => error.Exists,
        else => error.Io,
    };
}

var start_ms: ?f64 = null;

pub fn nowMs() i64 {
    const now = js_now_ms();
    if (start_ms == null) start_ms = now;
    return @intFromFloat(now - start_ms.?);
}

const host = @import("host.zig");

pub fn realClock() host.Clock {
    return .{
        .unix_ms = @intFromFloat(js_wall_clock_ms()),
        .utc_offset_min = js_utc_offset_min(),
    };
}

pub fn log(str: []const u8) void {
    js_log(str.ptr, str.len);
}
