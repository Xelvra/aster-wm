//! Registers the `host` table (twelve functions, spec/host-contract.md) and
//! a separate, undocumented `__native_render` table that only
//! lua/aster/render.lua touches — the renderer is a shared Zig library
//! (spec/architecture.md's "Four rules", rule 3), not part of the host
//! contract itself.

const std = @import("std");
const build_options = @import("build_options");
const lua = @import("lua.zig");
const c = lua.c;
const host_mod = @import("host.zig");
const fs = @import("fs.zig");
const renderer = @import("../render/renderer.zig");
const Surface = renderer.Surface;

// Set once by `register`, from the allocator `main.zig` got out of
// `std.process.Init` — this module doesn't own an allocator itself.
var allocator: std.mem.Allocator = undefined;
var active_backend: host_mod.Backend = undefined;

fn pushError(L: *c.lua_State, err: fs.HostError) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, fs.errName(err).ptr);
    return 2;
}

fn checkString(L: *c.lua_State, idx: c_int) []const u8 {
    var len: usize = 0;
    const p = c.luaL_checklstring(L, idx, &len);
    return p[0..len];
}

// __native_render is the one boundary where "the input can't occur" does
// not hold (spec/code-style.md): unlike host.*/aster.*, which is Zig
// calling Zig, this is called directly by arbitrary app Lua. A wrong or
// missing argument here must become a Lua error that `pcall`/`wm:guard`
// can catch and turn into a closed window, never a Zig panic that takes
// the whole process down with it — see B17 in spec/troubleshooting.md.
fn surfaceArg(L: *c.lua_State, idx: c_int) *Surface {
    if (c.lua_type(L, idx) != c.LUA_TLIGHTUSERDATA) {
        _ = c.luaL_argerror(L, idx, "expected a surface (as returned by host.surface())");
        unreachable;
    }
    const p = c.lua_touserdata(L, idx);
    return @ptrCast(@alignCast(p));
}

// Bounds-checked replacements for `@intCast(luaL_checkinteger(...))` — see
// B17 in spec/troubleshooting.md.
fn checkI32(L: *c.lua_State, idx: c_int) i32 {
    const v = c.luaL_checkinteger(L, idx);
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) {
        _ = c.luaL_argerror(L, idx, "value does not fit in a 32-bit coordinate");
        unreachable;
    }
    return @intCast(v);
}

fn checkU32(L: *c.lua_State, idx: c_int) u32 {
    const v = c.luaL_checkinteger(L, idx);
    if (v < 0 or v > std.math.maxInt(u32)) {
        _ = c.luaL_argerror(L, idx, "value does not fit in an unsigned 32-bit size");
        unreachable;
    }
    return @intCast(v);
}

// `host` is a global table reachable from any app's Lua exactly like
// __native_render is — see B31 in spec/troubleshooting.md. optI32 is the
// host.* counterpart of checkI32 for arguments that are optional
// (luaL_optinteger's default is used when the argument is absent).
fn optI32(L: *c.lua_State, idx: c_int, default: i32) i32 {
    const v = c.luaL_optinteger(L, idx, default);
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) {
        _ = c.luaL_argerror(L, idx, "value does not fit in a 32-bit coordinate");
        unreachable;
    }
    return @intCast(v);
}

// ---- host.* -----------------------------------------------------------

fn lInfo(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const info = active_backend.info();

    c.lua_createtable(st, 0, 6);

    _ = c.lua_pushlstring(st, info.backend.ptr, info.backend.len);
    c.lua_setfield(st, -2, "backend");
    _ = c.lua_pushlstring(st, info.format.ptr, info.format.len);
    c.lua_setfield(st, -2, "format");
    c.lua_pushinteger(st, @intCast(info.pitch));
    c.lua_setfield(st, -2, "pitch");

    c.lua_createtable(st, @intCast(info.outputs.len), 0);
    for (info.outputs, 0..) |o, i| {
        c.lua_createtable(st, 0, 6);
        c.lua_pushinteger(st, o.id);
        c.lua_setfield(st, -2, "id");
        c.lua_pushinteger(st, o.x);
        c.lua_setfield(st, -2, "x");
        c.lua_pushinteger(st, o.y);
        c.lua_setfield(st, -2, "y");
        c.lua_pushinteger(st, @intCast(o.w));
        c.lua_setfield(st, -2, "w");
        c.lua_pushinteger(st, @intCast(o.h));
        c.lua_setfield(st, -2, "h");
        c.lua_pushnumber(st, o.scale);
        c.lua_setfield(st, -2, "scale");
        c.lua_pushboolean(st, @intFromBool(o.primary));
        c.lua_setfield(st, -2, "primary");
        c.lua_seti(st, -2, @intCast(i + 1));
    }
    c.lua_setfield(st, -2, "outputs");

    c.lua_createtable(st, 0, 3);
    _ = c.lua_pushlstring(st, info.paths.config.ptr, info.paths.config.len);
    c.lua_setfield(st, -2, "config");
    _ = c.lua_pushlstring(st, info.paths.data.ptr, info.paths.data.len);
    c.lua_setfield(st, -2, "data");
    _ = c.lua_pushlstring(st, info.paths.home.ptr, info.paths.home.len);
    c.lua_setfield(st, -2, "home");
    c.lua_setfield(st, -2, "paths");

    c.lua_createtable(st, 0, 4);
    c.lua_pushboolean(st, @intFromBool(info.caps.clock));
    c.lua_setfield(st, -2, "clock");
    c.lua_pushboolean(st, @intFromBool(info.caps.spawn));
    c.lua_setfield(st, -2, "spawn");
    c.lua_pushboolean(st, @intFromBool(info.caps.damage));
    c.lua_setfield(st, -2, "damage");
    c.lua_pushboolean(st, @intFromBool(info.caps.inject));
    c.lua_setfield(st, -2, "inject");
    c.lua_setfield(st, -2, "caps");

    return 1;
}

fn lSurface(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = active_backend.surface();
    c.lua_pushlightuserdata(st, s);
    return 1;
}

fn lPresent(L: ?*c.lua_State) callconv(.c) c_int {
    _ = L;
    active_backend.present();
    return 0;
}

fn keyOf(tag: host_mod.EventTag) [:0]const u8 {
    return switch (tag) {
        .key_down => "key_down",
        .key_up => "key_up",
        .text => "text",
        .mouse_move => "mouse_move",
        .mouse_down => "mouse_down",
        .mouse_up => "mouse_up",
        .scroll => "scroll",
        .resize => "resize",
        .focus => "focus",
        .quit => "quit",
    };
}

fn pushMods(st: *c.lua_State, m: host_mod.Mods) void {
    c.lua_createtable(st, 0, 4);
    c.lua_pushboolean(st, @intFromBool(m.ctrl));
    c.lua_setfield(st, -2, "ctrl");
    c.lua_pushboolean(st, @intFromBool(m.alt));
    c.lua_setfield(st, -2, "alt");
    c.lua_pushboolean(st, @intFromBool(m.shift));
    c.lua_setfield(st, -2, "shift");
    c.lua_pushboolean(st, @intFromBool(m.super));
    c.lua_setfield(st, -2, "super");
    c.lua_setfield(st, -2, "mods");
}

fn buttonName(b: host_mod.MouseButton) [:0]const u8 {
    return switch (b) {
        .left => "left",
        .right => "right",
        .middle => "middle",
    };
}

fn pushEvent(st: *c.lua_State, ev: host_mod.Event) void {
    c.lua_createtable(st, 0, 5);
    _ = c.lua_pushstring(st, keyOf(std.meta.activeTag(ev)).ptr);
    c.lua_setfield(st, -2, "type");
    switch (ev) {
        .key_down => |e| {
            _ = c.lua_pushlstring(st, e.key.ptr, e.key.len);
            c.lua_setfield(st, -2, "key");
            pushMods(st, e.mods);
        },
        .key_up => |e| {
            _ = c.lua_pushlstring(st, e.key.ptr, e.key.len);
            c.lua_setfield(st, -2, "key");
            pushMods(st, e.mods);
        },
        .text => |e| {
            _ = c.lua_pushlstring(st, e.text.ptr, e.text.len);
            c.lua_setfield(st, -2, "text");
        },
        .mouse_move => |e| {
            c.lua_pushinteger(st, e.x);
            c.lua_setfield(st, -2, "x");
            c.lua_pushinteger(st, e.y);
            c.lua_setfield(st, -2, "y");
            c.lua_pushinteger(st, e.dx);
            c.lua_setfield(st, -2, "dx");
            c.lua_pushinteger(st, e.dy);
            c.lua_setfield(st, -2, "dy");
        },
        .mouse_down => |e| {
            c.lua_pushinteger(st, e.x);
            c.lua_setfield(st, -2, "x");
            c.lua_pushinteger(st, e.y);
            c.lua_setfield(st, -2, "y");
            _ = c.lua_pushstring(st, buttonName(e.button).ptr);
            c.lua_setfield(st, -2, "button");
        },
        .mouse_up => |e| {
            c.lua_pushinteger(st, e.x);
            c.lua_setfield(st, -2, "x");
            c.lua_pushinteger(st, e.y);
            c.lua_setfield(st, -2, "y");
            _ = c.lua_pushstring(st, buttonName(e.button).ptr);
            c.lua_setfield(st, -2, "button");
        },
        .scroll => |e| {
            c.lua_pushinteger(st, e.x);
            c.lua_setfield(st, -2, "x");
            c.lua_pushinteger(st, e.y);
            c.lua_setfield(st, -2, "y");
            c.lua_pushinteger(st, e.dx);
            c.lua_setfield(st, -2, "dx");
            c.lua_pushinteger(st, e.dy);
            c.lua_setfield(st, -2, "dy");
        },
        .resize => |e| {
            c.lua_pushinteger(st, @intCast(e.w));
            c.lua_setfield(st, -2, "w");
            c.lua_pushinteger(st, @intCast(e.h));
            c.lua_setfield(st, -2, "h");
        },
        .focus => |e| {
            c.lua_pushboolean(st, @intFromBool(e.focused));
            c.lua_setfield(st, -2, "focused");
        },
        .quit => {},
    }
}

fn lWait(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const timeout: i32 = optI32(st, 1, 0);
    const ev = active_backend.wait(timeout) orelse {
        c.lua_pushnil(st);
        return 1;
    };
    pushEvent(st, ev);
    return 1;
}

fn lNowMs(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    c.lua_pushnumber(st, @floatFromInt(fs.nowMs()));
    return 1;
}

fn lClock(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const cl = active_backend.clock() orelse return pushError(st, error.Unsupported);
    c.lua_createtable(st, 0, 2);
    c.lua_pushnumber(st, @floatFromInt(cl.unix_ms));
    c.lua_setfield(st, -2, "unix_ms");
    c.lua_pushinteger(st, cl.utc_offset_min);
    c.lua_setfield(st, -2, "utc_offset_min");
    return 1;
}

fn lRead(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const path = checkString(st, 1);
    const data = fs.read(allocator, path) catch |e| return pushError(st, e);
    defer allocator.free(data);
    _ = c.lua_pushlstring(st, data.ptr, data.len);
    return 1;
}

fn lWrite(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const path = checkString(st, 1);
    const data = checkString(st, 2);
    fs.write(path, data) catch |e| return pushError(st, e);
    c.lua_pushboolean(st, 1);
    return 1;
}

fn lList(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const path = checkString(st, 1);
    const entries = fs.list(allocator, path) catch |e| return pushError(st, e);
    defer {
        for (entries) |e| allocator.free(e.name);
        allocator.free(entries);
    }
    c.lua_createtable(st, @intCast(entries.len), 0);
    for (entries, 0..) |e, i| {
        c.lua_createtable(st, 0, 4);
        _ = c.lua_pushlstring(st, e.name.ptr, e.name.len);
        c.lua_setfield(st, -2, "name");
        c.lua_pushboolean(st, @intFromBool(e.dir));
        c.lua_setfield(st, -2, "dir");
        c.lua_pushinteger(st, @intCast(e.size));
        c.lua_setfield(st, -2, "size");
        c.lua_pushinteger(st, @intCast(e.mtime));
        c.lua_setfield(st, -2, "mtime");
        c.lua_seti(st, -2, @intCast(i + 1));
    }
    return 1;
}

fn lRemove(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const path = checkString(st, 1);
    fs.remove(path) catch |e| return pushError(st, e);
    c.lua_pushboolean(st, 1);
    return 1;
}

fn lRename(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const from = checkString(st, 1);
    const to = checkString(st, 2);
    fs.rename(from, to) catch |e| return pushError(st, e);
    c.lua_pushboolean(st, 1);
    return 1;
}

fn lLog(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = checkString(st, 1);
    fs.log(s);
    return 0;
}

// ---- host._inject (conformance builds only — see host-contract.md's
// "Events" section for what this is and why) -----------------------------
// Everything below this line is compiled out of `aster` (only
// `aster-conformance` gets it, see build.zig's two-executable split):
// `register` never calls `lua_setfield(..., "_inject")` unless
// build_options.conformance.

fn getStringField(L: *c.lua_State, idx: c_int, name: [:0]const u8, buf: []u8) []const u8 {
    _ = c.lua_getfield(L, idx, name.ptr);
    defer c.lua_pop(L, 1);
    var len: usize = 0;
    const p = c.lua_tolstring(L, -1, &len) orelse return "";
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], p[0..n]);
    return buf[0..n];
}

fn getIntField(L: *c.lua_State, idx: c_int, name: [:0]const u8, default: i64) i64 {
    _ = c.lua_getfield(L, idx, name.ptr);
    defer c.lua_pop(L, 1);
    if (c.lua_isnil(L, -1)) return default;
    return @intCast(c.lua_tointegerx(L, -1, null));
}

fn getBoolField(L: *c.lua_State, idx: c_int, name: [:0]const u8) bool {
    _ = c.lua_getfield(L, idx, name.ptr);
    defer c.lua_pop(L, 1);
    return c.lua_toboolean(L, -1) != 0;
}

fn getModsField(L: *c.lua_State, idx: c_int) host_mod.Mods {
    _ = c.lua_getfield(L, idx, "mods");
    defer c.lua_pop(L, 1);
    const mods_idx = c.lua_gettop(L);
    if (c.lua_isnil(L, mods_idx)) return .{};
    return .{
        .ctrl = getBoolField(L, mods_idx, "ctrl"),
        .alt = getBoolField(L, mods_idx, "alt"),
        .shift = getBoolField(L, mods_idx, "shift"),
        .super = getBoolField(L, mods_idx, "super"),
    };
}

fn buttonFromName(name: []const u8) host_mod.MouseButton {
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "middle")) return .middle;
    return .left;
}

fn lInject(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    var key_buf: [32]u8 = undefined;
    var text_buf: [64]u8 = undefined;
    var type_buf: [16]u8 = undefined;
    const ev_type = getStringField(st, 1, "type", &type_buf);

    const ev: host_mod.Event = blk: {
        if (std.mem.eql(u8, ev_type, "key_down")) {
            break :blk .{ .key_down = .{ .key = getStringField(st, 1, "key", &key_buf), .mods = getModsField(st, 1) } };
        } else if (std.mem.eql(u8, ev_type, "key_up")) {
            break :blk .{ .key_up = .{ .key = getStringField(st, 1, "key", &key_buf), .mods = getModsField(st, 1) } };
        } else if (std.mem.eql(u8, ev_type, "text")) {
            break :blk .{ .text = .{ .text = getStringField(st, 1, "text", &text_buf) } };
        } else if (std.mem.eql(u8, ev_type, "mouse_move")) {
            break :blk .{ .mouse_move = .{
                .x = @intCast(getIntField(st, 1, "x", 0)),
                .y = @intCast(getIntField(st, 1, "y", 0)),
                .dx = @intCast(getIntField(st, 1, "dx", 0)),
                .dy = @intCast(getIntField(st, 1, "dy", 0)),
            } };
        } else if (std.mem.eql(u8, ev_type, "mouse_down")) {
            var btn_buf: [8]u8 = undefined;
            break :blk .{ .mouse_down = .{
                .x = @intCast(getIntField(st, 1, "x", 0)),
                .y = @intCast(getIntField(st, 1, "y", 0)),
                .button = buttonFromName(getStringField(st, 1, "button", &btn_buf)),
            } };
        } else if (std.mem.eql(u8, ev_type, "mouse_up")) {
            var btn_buf: [8]u8 = undefined;
            break :blk .{ .mouse_up = .{
                .x = @intCast(getIntField(st, 1, "x", 0)),
                .y = @intCast(getIntField(st, 1, "y", 0)),
                .button = buttonFromName(getStringField(st, 1, "button", &btn_buf)),
            } };
        } else if (std.mem.eql(u8, ev_type, "scroll")) {
            break :blk .{ .scroll = .{
                .x = @intCast(getIntField(st, 1, "x", 0)),
                .y = @intCast(getIntField(st, 1, "y", 0)),
                .dx = @intCast(getIntField(st, 1, "dx", 0)),
                .dy = @intCast(getIntField(st, 1, "dy", 0)),
            } };
        } else if (std.mem.eql(u8, ev_type, "resize")) {
            break :blk .{ .resize = .{ .w = @intCast(getIntField(st, 1, "w", 0)), .h = @intCast(getIntField(st, 1, "h", 0)) } };
        } else if (std.mem.eql(u8, ev_type, "focus")) {
            break :blk .{ .focus = .{ .focused = getBoolField(st, 1, "focused") } };
        } else if (std.mem.eql(u8, ev_type, "quit")) {
            break :blk .{ .quit = .{} };
        } else {
            return c.luaL_error(st, "host._inject: unknown event type");
        }
    };

    c.lua_pushboolean(st, @intFromBool(active_backend.inject(ev)));
    return 1;
}

// ---- native render (not part of the host contract) ---------------------

fn colorArg(L: *c.lua_State, idx: c_int) u32 {
    return checkU32(L, idx);
}

// An optional trailing alpha argument (0-255, default 255 — opaque, so
// every existing fill_rect/round_rect call site is unaffected).
// Not colorArg's high byte: colorArg is checkU32, so a 0xAARRGGBB value
// would silently pass through and then get its alpha byte discarded by
// pack() — an explicit argument can't be lost that way.
fn optAlpha(L: *c.lua_State, idx: c_int) u8 {
    const v = c.luaL_optinteger(L, idx, 255);
    if (v < 0 or v > 255) {
        _ = c.luaL_argerror(L, idx, "alpha must be 0-255");
        unreachable;
    }
    return @intCast(v);
}

fn nFillRect(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    renderer.fillRect(s, checkI32(st, 2), checkI32(st, 3), checkU32(st, 4), checkU32(st, 5), colorArg(st, 6), optAlpha(st, 7));
    return 0;
}

fn nRoundRect(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    renderer.roundRect(s, checkI32(st, 2), checkI32(st, 3), checkU32(st, 4), checkU32(st, 5), checkU32(st, 6), colorArg(st, 7), optAlpha(st, 8));
    return 0;
}

fn nRectBorder(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    renderer.rectBorder(s, checkI32(st, 2), checkI32(st, 3), checkU32(st, 4), checkU32(st, 5), checkU32(st, 6), colorArg(st, 7));
    return 0;
}

fn nGradientBorder(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    renderer.gradientBorder(s, checkI32(st, 2), checkI32(st, 3), checkU32(st, 4), checkU32(st, 5), checkU32(st, 6), colorArg(st, 7), colorArg(st, 8));
    return 0;
}

fn nGlyph(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    renderer.drawGlyphRow(s, checkI32(st, 2), checkI32(st, 3), checkU32(st, 4), colorArg(st, 5));
    return 0;
}

fn nText(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    const text = checkString(st, 4);
    renderer.drawText(s, checkI32(st, 2), checkI32(st, 3), text, colorArg(st, 5));
    return 0;
}

fn nTextWidth(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const text = checkString(st, 1);
    c.lua_pushinteger(st, @intCast(renderer.textWidth(text)));
    return 1;
}

fn nLineHeight(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    c.lua_pushinteger(st, @intCast(renderer.lineHeight()));
    return 1;
}

fn nPushClip(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    s.pushClip(.{
        .x = checkI32(st, 2),
        .y = checkI32(st, 3),
        .w = checkU32(st, 4),
        .h = checkU32(st, 5),
    });
    return 0;
}

fn nPopClip(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    s.popClip();
    return 0;
}

// clip_depth/restore_clip let lua/aster/render.lua's `clipped` guarantee the
// clip stack is back to where it found it once `fn` returns, even if `fn`
// itself called push_clip/pop_clip an unbalanced number of times — see B32
// in spec/troubleshooting.md.
fn nClipDepth(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    c.lua_pushinteger(st, s.clipDepth());
    return 1;
}

fn nRestoreClip(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    s.restoreClip(checkU32(st, 2));
    return 0;
}

// Not part of the drawing API a theme or app ever needs — read-back exists
// purely so spec/conformance/02_surface.lua can verify a write landed.
fn nGetPixel(L: ?*c.lua_State) callconv(.c) c_int {
    const st = L.?;
    const s = surfaceArg(st, 1);
    const color = s.getPixel(checkI32(st, 2), checkI32(st, 3));
    c.lua_pushinteger(st, @intCast(color & 0x00ffffff));
    return 1;
}

pub fn register(L: *c.lua_State, backend: host_mod.Backend, gpa: std.mem.Allocator) void {
    active_backend = backend;
    allocator = gpa;

    const host_funcs = [_]c.luaL_Reg{
        .{ .name = "info", .func = lInfo },
        .{ .name = "surface", .func = lSurface },
        .{ .name = "present", .func = lPresent },
        .{ .name = "wait", .func = lWait },
        .{ .name = "now_ms", .func = lNowMs },
        .{ .name = "clock", .func = lClock },
        .{ .name = "read", .func = lRead },
        .{ .name = "write", .func = lWrite },
        .{ .name = "list", .func = lList },
        .{ .name = "remove", .func = lRemove },
        .{ .name = "rename", .func = lRename },
        .{ .name = "log", .func = lLog },
        .{ .name = null, .func = null },
    };
    c.lua_createtable(L, 0, @intCast(host_funcs.len - 1));
    c.luaL_setfuncs(L, &host_funcs, 0);
    if (build_options.conformance) {
        c.lua_pushcfunction(L, lInject);
        c.lua_setfield(L, -2, "_inject");
    }
    c.lua_setglobal(L, "host");

    const render_funcs = [_]c.luaL_Reg{
        .{ .name = "fill_rect", .func = nFillRect },
        .{ .name = "round_rect", .func = nRoundRect },
        .{ .name = "rect_border", .func = nRectBorder },
        .{ .name = "gradient_border", .func = nGradientBorder },
        .{ .name = "glyph", .func = nGlyph },
        .{ .name = "text", .func = nText },
        .{ .name = "text_width", .func = nTextWidth },
        .{ .name = "line_height", .func = nLineHeight },
        .{ .name = "push_clip", .func = nPushClip },
        .{ .name = "pop_clip", .func = nPopClip },
        .{ .name = "clip_depth", .func = nClipDepth },
        .{ .name = "restore_clip", .func = nRestoreClip },
        .{ .name = "get_pixel", .func = nGetPixel },
        .{ .name = null, .func = null },
    };
    c.lua_createtable(L, 0, @intCast(render_funcs.len - 1));
    c.luaL_setfuncs(L, &render_funcs, 0);
    c.lua_setglobal(L, "__native_render");
}
