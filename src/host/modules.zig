//! Package searcher for the Lua core (ADR-015): resolves `require("aster.wm")`
//! and friends against Lua compiled into the binary, not the filesystem.
//! Used two ways, one per backend:
//!
//! - wasm has no real filesystem (fopen always fails, see
//!   backends/wasm/vendor/stdio.h) for loadlib.c's normal Lua-file searcher
//!   to find anything in, so this is registered FIRST — it's the only
//!   searcher that can ever succeed there.
//! - every other backend still searches `lua/?.lua` etc. on disk first
//!   (src/host/lua.zig's package.path) — a developer's checkout wins, so
//!   editing lua/aster/*.lua keeps working with no rebuild. This is
//!   registered LAST, as the fallback for a binary running outside its own
//!   checkout (ADR-012's original gap, closed by ADR-015): a downloaded
//!   release binary, or `aster` invoked from any other working directory.
//!
//! `config/wm.lua` is deliberately not a module here — it's a *seed*, not
//! a library. See `default_config_source`/`pushDefaultConfig` below.

const std = @import("std");
const lua = @import("lua.zig");
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
    .{ .name = "aster.bar", .source = @embedFile("lua/aster/bar.lua") },
    .{ .name = "aster.launcher", .source = @embedFile("lua/aster/launcher.lua") },
    .{ .name = "apps.hello-window", .source = @embedFile("apps/hello-window.lua") },
    .{ .name = "apps.editor", .source = @embedFile("apps/editor.lua") },
    .{ .name = "apps.plasma", .source = @embedFile("apps/plasma.lua") },
    .{ .name = "apps.snake", .source = @embedFile("apps/snake.lua") },
    .{ .name = "apps.calculator", .source = @embedFile("apps/calculator.lua") },
    .{ .name = "apps.theme-switcher", .source = @embedFile("apps/theme-switcher.lua") },
    // widgets/: a different contract than apps/ — draw(bar, surface, x, y,
    // h) -> width, registered into a bar (lua/aster/bar.lua), never opened
    // as a window. Kept in a separate directory so the two shapes don't
    // blur together the way they briefly did during M6.
    .{ .name = "widgets.clock-widget", .source = @embedFile("widgets/clock-widget.lua") },
    .{ .name = "widgets.workspace-widget", .source = @embedFile("widgets/workspace-widget.lua") },
    .{ .name = "widgets.active-window-widget", .source = @embedFile("widgets/active-window-widget.lua") },
    .{ .name = "widgets.sysmon-widget", .source = @embedFile("widgets/sysmon-widget.lua") },
    .{ .name = "widgets.launcher-button", .source = @embedFile("widgets/launcher-button.lua") },
    .{ .name = "themes.default", .source = @embedFile("themes/default.lua") },
    .{ .name = "themes.nord", .source = @embedFile("themes/nord.lua") },
    .{ .name = "themes.catppuccin-mocha", .source = @embedFile("themes/catppuccin-mocha.lua") },
    .{ .name = "themes.gruvbox", .source = @embedFile("themes/gruvbox.lua") },
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

pub const Order = enum { first, last };

// `first`: insert ahead of every other searcher (wasm — nothing else could
// ever succeed there). `last`: append after Lua's own preload/C-loader/
// Lua-file searchers, so a real file on disk always wins over the
// embedded copy.
pub fn register(L: ?*c.lua_State, order: Order) void {
    _ = c.lua_getglobal(L, "package");
    _ = c.lua_getfield(L, -1, "searchers");
    const n = c.luaL_len(L, -1);
    switch (order) {
        .first => {
            var i: c.lua_Integer = n;
            while (i >= 1) : (i -= 1) {
                _ = c.lua_geti(L, -1, i);
                c.lua_seti(L, -2, i + 1);
            }
            c.lua_pushcfunction(L, searcher);
            c.lua_seti(L, -2, 1);
        },
        .last => {
            c.lua_pushcfunction(L, searcher);
            c.lua_seti(L, -2, n + 1);
        },
    }
    c.lua_pop(L, 2); // searchers, package
}

// config/wm.lua's shipped text, embedded the same way the modules above
// are — but exposed as a plain string, never registered as a module: this
// is what lua/aster/loop.lua's M.boot() writes to
// `<paths.config>/wm.lua` the first time that file doesn't exist (ADR-015),
// so a fresh install — native or the wasm demo — boots into the real
// desktop instead of the bare fallback screen. Not part of host.* (P2:
// twelve functions, no more) — a second infrastructure global alongside
// __native_render, touched only by loop.lua.
const default_config_source: [:0]const u8 = @embedFile("config/wm.lua");

pub fn pushDefaultConfig(L: ?*c.lua_State) void {
    _ = c.lua_pushlstring(L, default_config_source.ptr, default_config_source.len);
    c.lua_setglobal(L, "__aster_default_config");
}
