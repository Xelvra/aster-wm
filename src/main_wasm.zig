//! The wasm backend's entry point (ADR-002's frame-loop inversion): the
//! browser drives via `requestAnimationFrame`, calling into the three
//! `aster_*` exports below instead of this file owning a loop the way
//! src/main.zig's `while (true)` does for SDL. Events arrive the same
//! way — pushed from JS (src/backends/wasm/glue.js) through the
//! `aster_push_*` exports, into the queue src/backends/wasm/backend.zig
//! already owns.

const std = @import("std");
const build_options = @import("build_options");
const lua = @import("host/lua.zig");
const wasm_backend = @import("backends/wasm/backend.zig");
const renderer = @import("render/renderer.zig");
const host_mod = @import("host/host.zig");

// libc.zig's `export fn`s (malloc, strcmp, snprintf, ...) are otherwise
// never referenced by name from Zig code in this module — nothing here
// calls `malloc()` directly, the vendored Lua C sources do — so without
// this, Zig never analyzes that file and every one of those symbols
// comes up undefined at link time (or worse, silently becomes a bogus
// wasm import if the linker doesn't treat that as an error).
comptime {
    _ = @import("backends/wasm/libc.zig");
}

const allocator = std.heap.wasm_allocator;

var g_wasm: wasm_backend.Wasm = undefined;
var g_state: lua.State = undefined;
var g_frame_buf: [16]u8 = undefined;

export fn aster_init(w: u32, h: u32) void {
    renderer.initFont(allocator);
    g_wasm = wasm_backend.Wasm.init(allocator, w, h) catch @panic("wasm backend init failed");
    g_state = lua.State.init(allocator, g_wasm.backend()) catch @panic("lua state init failed");
}

export fn aster_boot() void {
    g_state.boot() catch {};
}

/// Return value matches ADR-002's JS example exactly: 0 = "running",
/// 1 = "idle" (JS keeps calling requestAnimationFrame regardless — there
/// is nothing to block on here, see backend.zig's header comment), 2 = "quit".
export fn aster_frame() i32 {
    const status = g_state.frame(&g_frame_buf) catch return 2;
    if (std.mem.eql(u8, status, "quit")) return 2;
    if (std.mem.eql(u8, status, "idle")) return 1;
    return 0;
}

export fn aster_shutdown() void {
    g_state.shutdown() catch {};
    renderer.deinitFont();
}

// ---- events, pushed from JS ------------------------------------------
//
// A wasm import can only pass numbers, so key/text bytes are written into
// this module's own linear memory first (JS calls the exported `malloc`
// libc.zig provides, writes through the memory buffer, then calls one of
// these) rather than passed as JS strings directly.

fn modsFrom(ctrl: i32, alt: i32, shift: i32, super: i32) host_mod.Mods {
    return .{ .ctrl = ctrl != 0, .alt = alt != 0, .shift = shift != 0, .super = super != 0 };
}

export fn aster_push_key_down(key_ptr: [*]const u8, key_len: usize, ctrl: i32, alt: i32, shift: i32, super: i32) void {
    g_wasm.pushKeyDown(key_ptr[0..key_len], modsFrom(ctrl, alt, shift, super));
}
export fn aster_push_key_up(key_ptr: [*]const u8, key_len: usize, ctrl: i32, alt: i32, shift: i32, super: i32) void {
    g_wasm.pushKeyUp(key_ptr[0..key_len], modsFrom(ctrl, alt, shift, super));
}
export fn aster_push_text(text_ptr: [*]const u8, text_len: usize) void {
    g_wasm.pushText(text_ptr[0..text_len]);
}
export fn aster_push_mouse_move(x: i32, y: i32, dx: i32, dy: i32) void {
    g_wasm.pushMouseMove(x, y, dx, dy);
}
export fn aster_push_mouse_down(x: i32, y: i32, button: i32) void {
    g_wasm.pushMouseDown(x, y, mouseButtonFrom(button));
}
export fn aster_push_mouse_up(x: i32, y: i32, button: i32) void {
    g_wasm.pushMouseUp(x, y, mouseButtonFrom(button));
}
fn mouseButtonFrom(button: i32) host_mod.MouseButton {
    return switch (button) {
        1 => .right,
        2 => .middle,
        else => .left,
    };
}
export fn aster_push_scroll(x: i32, y: i32, dx: i32, dy: i32) void {
    g_wasm.pushScroll(x, y, dx, dy);
}
export fn aster_push_resize(w: u32, h: u32) void {
    g_wasm.pushResize(w, h);
}
export fn aster_push_focus(focused: i32) void {
    g_wasm.pushFocus(focused != 0);
}
export fn aster_push_quit() void {
    g_wasm.pushQuit();
}

// ---- conformance-only: spec/conformance/*.lua, run against the real
// host.* table (src/host/lua.zig's runScript does the same thing on
// every other backend, but through luaL_loadfilex — no filesystem here,
// so this loads from the @embedFile'd source below instead, then shares
// runScript's runLoaded for the pcall/skip/error handling). Same three
// exit codes: 0 pass, 1 fail, 2 declared skip.
//
// Gated on `comptime build_options.conformance` around the @embedFile
// calls themselves, not just inside the function body below — build.zig
// only maps spec/conformance/*.lua into the aster-wasm-conformance build
// (its `embedded_conformance`), so in the release aster-wasm binary these
// names resolve to nothing and must never be analyzed. As with
// backends/wasm/modules.zig, the strings are those module names, not paths
// relative to this file.

const ConformanceScript = struct { name: [:0]const u8, source: [:0]const u8 };

const conformance_scripts: [7]ConformanceScript = if (build_options.conformance) .{
    .{ .name = "01_info", .source = @embedFile("spec/conformance/01_info.lua") },
    .{ .name = "02_surface", .source = @embedFile("spec/conformance/02_surface.lua") },
    .{ .name = "03_present", .source = @embedFile("spec/conformance/03_present.lua") },
    .{ .name = "04_events", .source = @embedFile("spec/conformance/04_events.lua") },
    .{ .name = "05_time", .source = @embedFile("spec/conformance/05_time.lua") },
    .{ .name = "06_fs", .source = @embedFile("spec/conformance/06_fs.lua") },
    .{ .name = "07_resize", .source = @embedFile("spec/conformance/07_resize.lua") },
} else undefined;

export fn aster_run_conformance(name_ptr: [*]const u8, name_len: usize) i32 {
    if (comptime !build_options.conformance) return -1;
    const name = name_ptr[0..name_len];
    const script = for (&conformance_scripts) |*s| {
        if (std.mem.eql(u8, s.name, name)) break s;
    } else return -1;

    var chunk_name_buf: [64]u8 = undefined;
    const chunk_name = std.fmt.bufPrintZ(&chunk_name_buf, "@{s}.lua", .{script.name}) catch "@conformance";
    if (lua.c.luaL_loadbufferx(g_state.L, script.source.ptr, script.source.len, chunk_name.ptr, null) != lua.c.LUA_OK) {
        g_state.reportError();
        return 1;
    }
    return g_state.runLoaded();
}
