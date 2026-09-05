//! The Zig <-> Lua bridge: state creation, library loading, and the three
//! calls the host makes into Lua (aster.boot/frame/shutdown), per
//! spec/host-contract.md's lifecycle section.

const std = @import("std");
pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
const bindings = @import("bindings.zig");
const host_mod = @import("host.zig");

pub const State = struct {
    L: *c.lua_State,

    pub fn init(allocator: std.mem.Allocator, backend: host_mod.Backend) !State {
        const L = c.luaL_newstate() orelse return error.OutOfMemory;
        c.luaL_requiref(L, "_G", c.luaopen_base, 1);
        c.lua_pop(L, 1);
        c.luaL_requiref(L, c.LUA_TABLIBNAME, c.luaopen_table, 1);
        c.lua_pop(L, 1);
        c.luaL_requiref(L, c.LUA_STRLIBNAME, c.luaopen_string, 1);
        c.lua_pop(L, 1);
        c.luaL_requiref(L, c.LUA_MATHLIBNAME, c.luaopen_math, 1);
        c.lua_pop(L, 1);
        c.luaL_requiref(L, c.LUA_UTF8LIBNAME, c.luaopen_utf8, 1);
        c.lua_pop(L, 1);
        c.luaL_requiref(L, c.LUA_COLIBNAME, c.luaopen_coroutine, 1);
        c.lua_pop(L, 1);
        c.luaL_requiref(L, c.LUA_LOADLIBNAME, c.luaopen_package, 1);
        c.lua_pop(L, 1);

        bindings.register(L, backend, allocator);

        // package.path: lua/aster modules, then apps/themes/config relative
        // to the working directory the binary was launched from.
        _ = c.lua_getglobal(L, "package");
        _ = c.lua_pushstring(L, "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua");
        c.lua_setfield(L, -2, "path");
        c.lua_pop(L, 1);

        return .{ .L = L };
    }

    pub fn deinit(self: *State) void {
        c.lua_close(self.L);
    }

    fn callGlobalFunction(self: *State, path: []const u8, args: u8) !void {
        // path like "aster.boot": require("aster") then index .boot
        var it = std.mem.splitScalar(u8, path, '.');
        const first = it.first();
        _ = c.lua_getglobal(self.L, "require");
        _ = c.lua_pushlstring(self.L, first.ptr, first.len);
        if (c.lua_pcallk(self.L, 1, 1, 0, 0, null) != c.LUA_OK) {
            self.reportError();
            return error.LuaError;
        }
        while (it.next()) |field| {
            var buf: [64]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{field}) catch return error.LuaError;
            _ = c.lua_getfield(self.L, -1, z.ptr);
            c.lua_remove(self.L, -2);
        }
        // move the function below its args
        if (args > 0) c.lua_insert(self.L, -1 - @as(c_int, args));
        if (c.lua_pcallk(self.L, args, 0, 0, 0, null) != c.LUA_OK) {
            self.reportError();
            return error.LuaError;
        }
    }

    fn reportError(self: *State) void {
        const msg = c.lua_tolstring(self.L, -1, null);
        std.debug.print("lua error: {s}\n", .{msg});
        c.lua_pop(self.L, 1);
    }

    pub fn boot(self: *State) !void {
        try self.callGlobalFunction("aster.boot", 0);
    }

    /// Loads and runs a Lua file directly against the real host.* table —
    /// used by spec/conformance/ scripts, which assert on their own and
    /// never go through aster.boot()/the config loader. There's no `os`
    /// library compiled in (see build.zig), so a script that needs a
    /// backend capability it doesn't have signals that by erroring with a
    /// message starting "SKIP:" (spec/host-contract.md §9.4: a test a
    /// backend genuinely can't run becomes a manual release-checklist
    /// step, never a silent pass). Returns a process exit code: 0 on
    /// success, 1 on a real failure, 2 on a declared skip.
    pub fn runScript(self: *State, path: []const u8) !u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return 1;
        if (c.luaL_loadfilex(self.L, z.ptr, null) != c.LUA_OK) {
            self.reportError();
            return 1;
        }
        if (c.lua_pcallk(self.L, 0, 0, 0, 0, null) != c.LUA_OK) {
            var len: usize = 0;
            const msg = c.lua_tolstring(self.L, -1, &len);
            if (msg != null and len >= 5 and std.mem.eql(u8, msg[0..5], "SKIP:")) {
                std.debug.print("{s}\n", .{msg[0..len]});
                c.lua_pop(self.L, 1);
                return 2;
            }
            self.reportError();
            return 1;
        }
        return 0;
    }

    pub fn shutdown(self: *State) !void {
        try self.callGlobalFunction("aster.shutdown", 0);
    }

    /// Returns the "running" | "idle" | "quit" string frame() returned.
    pub fn frame(self: *State, buf: []u8) ![]const u8 {
        _ = c.lua_getglobal(self.L, "require");
        _ = c.lua_pushstring(self.L, "aster");
        if (c.lua_pcallk(self.L, 1, 1, 0, 0, null) != c.LUA_OK) {
            self.reportError();
            return error.LuaError;
        }
        _ = c.lua_getfield(self.L, -1, "frame");
        c.lua_remove(self.L, -2);
        if (c.lua_pcallk(self.L, 0, 1, 0, 0, null) != c.LUA_OK) {
            self.reportError();
            return error.LuaError;
        }
        var len: usize = 0;
        const s = c.lua_tolstring(self.L, -1, &len);
        const n = @min(len, buf.len - 1);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        c.lua_pop(self.L, 1);
        return buf[0..n];
    }
};
