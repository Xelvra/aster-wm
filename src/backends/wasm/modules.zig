//! Package searcher for the wasm backend: `require("aster.wm")` and
//! friends need to resolve to *something* despite there being no real
//! filesystem for Lua's normal file-based searcher (loadlib.c's
//! searcher_Lua) to find — the wasm backend never calls
//! luaL_loadfilex at all (fopen always fails, see vendor/stdio.h).
//!
//! `config/wm.lua` is deliberately not embedded here — it's loaded
//! through host.read (lua/aster/init.lua's M.reload), the same on every
//! backend, and lands in the browser's localStorage like any other file
//! this backend writes (src/host/fs_wasm.zig) so the hot-reload story
//! (edit wm.lua, Ctrl+S) works unchanged.
//!
//! Registered as package.searchers[1] — tried first, before Lua's own
//! preload/C-loader/Lua-file searchers, none of which can succeed here
//! anyway.

const std = @import("std");
const lua = @import("../../host/lua.zig");
const c = lua.c;

const Module = struct { name: [:0]const u8, source: [:0]const u8 };

// The paths below aren't relative to this file — they are module names
// build.zig maps to the real files (its `embedded_lua`), because
// @embedFile can't reach out of src/ on its own. Adding a module here
// means adding its path there too, or the build fails.
const modules = [_]Module{
    .{ .name = "aster", .source = @embedFile("lua/aster/init.lua") },
    .{ .name = "aster.init", .source = @embedFile("lua/aster/init.lua") },
    .{ .name = "aster.input", .source = @embedFile("lua/aster/input.lua") },
    .{ .name = "aster.loop", .source = @embedFile("lua/aster/loop.lua") },
    .{ .name = "aster.render", .source = @embedFile("lua/aster/render.lua") },
    .{ .name = "aster.wm", .source = @embedFile("lua/aster/wm.lua") },
    .{ .name = "apps.hello-window", .source = @embedFile("apps/hello-window.lua") },
};

fn findModule(name: []const u8) ?*const Module {
    for (&modules) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

fn searcher(L: ?*c.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const name_ptr = c.luaL_checklstring(L, 1, &len) orelse return 0;
    const name = name_ptr[0..len];

    const m = findModule(name) orelse {
        _ = c.lua_pushfstring(L, "\n\tno embedded module '%s'", name_ptr);
        return 1;
    };
    var name_buf: [128]u8 = undefined;
    const chunk_name_z = std.fmt.bufPrintZ(&name_buf, "@{s}", .{m.name}) catch "@embedded";
    if (c.luaL_loadbufferx(L, m.source.ptr, m.source.len, chunk_name_z.ptr, null) != c.LUA_OK) {
        return c.lua_error(L);
    }
    return 1;
}

pub fn register(L: ?*c.lua_State) void {
    _ = c.lua_getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "searchers");
    const n = c.luaL_len(L, -1);
    var i: c.lua_Integer = n;
    while (i >= 1) : (i -= 1) {
        _ = c.lua_geti(L, -1, i);
        c.lua_seti(L, -2, i + 1);
    }
    c.lua_pushcfunction(L, searcher);
    c.lua_seti(L, -2, 1);
    c.lua_pop(L, 2); // searchers, package
}
