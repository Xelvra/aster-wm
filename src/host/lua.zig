//! The Zig <-> Lua bridge: state creation, library loading, and the three
//! calls the host makes into Lua (aster.boot/frame/shutdown), per
//! spec/host-contract.md's lifecycle section.

const std = @import("std");
const builtin = @import("builtin");
pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
const bindings = @import("bindings.zig");
const host_mod = @import("host.zig");
const fs = @import("fs.zig");
const modules = @import("modules.zig");

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
        // to the working directory the binary was launched from. Dead
        // weight on the wasm backend (no real filesystem to search — see
        // vendor/stdio.h) but harmless: modules.zig's searcher runs first
        // there anyway, so this path is never even consulted.
        _ = c.lua_getglobal(L, "package");
        _ = c.lua_pushstring(L, "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua");
        c.lua_setfield(L, -2, "path");
        c.lua_pop(L, 1);

        // ADR-015: every backend gets the embedded-Lua searcher, ordered so
        // a real file on disk (a developer's checkout) always wins where
        // one can exist at all — see modules.zig's header comment.
        modules.register(L, if (comptime builtin.target.cpu.arch.isWasm()) .first else .last);
        modules.pushDefaultConfig(L);

        return .{ .L = L };
    }

    pub fn deinit(self: *State) void {
        c.lua_close(self.L);
    }

    // Calls a global Lua function by dotted path (e.g. "aster.boot") with
    // no arguments — the only shape either caller below needs.
    fn callGlobalFunction(self: *State, path: []const u8) !void {
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
        if (c.lua_pcallk(self.L, 0, 0, 0, 0, null) != c.LUA_OK) {
            self.reportError();
            return error.LuaError;
        }
    }

    // std.debug.print, not this, is the wrong tool here regardless of
    // backend: it needs a real stderr and (on this Zig version) a working
    // std.Io.Threaded default instance, neither of which the wasm backend
    // has — fs.log is already the host contract's diagnostic sink
    // (host.log, spec/host-contract.md §3.8) and works identically
    // everywhere.
    // pub: also called from main_wasm.zig's conformance runner, which
    // has no filesystem to go through luaL_loadfilex/runScript for.
    pub fn reportError(self: *State) void {
        const msg = c.lua_tolstring(self.L, -1, null);
        const msg_slice: []const u8 = if (msg) |m| std.mem.sliceTo(m, 0) else "(no message)";
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "lua error: {s}", .{msg_slice}) catch msg_slice;
        fs.log(line);
        c.lua_pop(self.L, 1);
    }

    pub fn boot(self: *State) !void {
        try self.callGlobalFunction("aster.boot");
    }

    /// Calls the function already on top of the stack (loaded by the
    /// caller — runScript below via luaL_loadfilex, main_wasm.zig's
    /// conformance runner via luaL_loadbufferx, since it has no
    /// filesystem to load a file from) with no arguments. Shared so the
    /// two callers can't drift on how a declared skip is reported (see
    /// B30 in spec/troubleshooting.md). Returns 0 on success, 1 on a real
    /// failure, 2 on a message starting "SKIP:" (spec/architecture.md's
    /// "Backends" section: a test a backend genuinely can't run becomes a
    /// manual release-checklist step, never a silent pass).
    pub fn runLoaded(self: *State) u8 {
        if (c.lua_pcallk(self.L, 0, 0, 0, 0, null) != c.LUA_OK) {
            var len: usize = 0;
            const msg = c.lua_tolstring(self.L, -1, &len);
            if (msg != null and len >= 5 and std.mem.eql(u8, msg[0..5], "SKIP:")) {
                fs.log(msg[0..len]);
                c.lua_pop(self.L, 1);
                return 2;
            }
            self.reportError();
            return 1;
        }
        return 0;
    }

    /// Loads and runs a Lua file directly against the real host.* table —
    /// used by spec/conformance/ scripts, which assert on their own and
    /// never go through aster.boot()/the config loader. Returns a process
    /// exit code, see runLoaded above.
    pub fn runScript(self: *State, path: []const u8) !u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return 1;
        if (c.luaL_loadfilex(self.L, z.ptr, null) != c.LUA_OK) {
            self.reportError();
            return 1;
        }
        return self.runLoaded();
    }

    pub fn shutdown(self: *State) !void {
        try self.callGlobalFunction("aster.shutdown");
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
        // loop.frame() always returns one of "running"/"idle"/"quit", so
        // this is unreachable today — checked anyway, since this was the
        // one place in this file reading a Lua return value without a
        // type check (compare reportError, runScript above).
        const str = s orelse {
            c.lua_pop(self.L, 1);
            return error.LuaError;
        };
        const n = @min(len, buf.len - 1);
        @memcpy(buf[0..n], str[0..n]);
        buf[n] = 0;
        c.lua_pop(self.L, 1);
        return buf[0..n];
    }
};
