//! The `wasm` backend: a `<canvas>` in a browser tab. Implements the
//! host.info/surface/present/wait/clock quintet; read/write/list/remove/
//! rename/now_ms/log are shared but backed by JS/localStorage on this
//! target (src/host/fs_wasm.zig) — see fs.zig's dispatcher.
//!
//! There is no OS event queue to poll (unlike SDL): events arrive
//! pushed from JS, one exported `aster_push_*` function per Event
//! variant (see the bottom of this file), called from the JS glue's own
//! DOM listeners. `wait()` drains that queue — ADR-002's inversion means
//! `aster.frame()` only ever calls `host.wait(0)`, so a real block is
//! only ever exercised by the conformance suite's own host.wait(50);
//! see `wait()` below for why that's a busy-wait, not a real block.

const std = @import("std");
const build_options = @import("build_options");
const host_mod = @import("../../host/host.zig");
const surface_mod = @import("../../render/surface.zig");
const fs = @import("../../host/fs.zig");
const Surface = surface_mod.Surface;

extern "aster" fn js_wall_clock_ms() f64;
extern "aster" fn js_utc_offset_min() i32;

pub const Wasm = struct {
    allocator: std.mem.Allocator,
    pixels: []u32,
    surface: Surface,
    outputs: [1]host_mod.Output,
    pending: [max_pending]PendingEvent = undefined,
    pending_head: usize = 0,
    pending_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) !Wasm {
        var self = Wasm{
            .allocator = allocator,
            .pixels = try allocator.alloc(u32, @as(usize, w) * h),
            .surface = undefined,
            .outputs = undefined,
        };
        self.rebuild(w, h);
        return self;
    }

    fn rebuild(self: *Wasm, w: u32, h: u32) void {
        self.surface = Surface.init(self.pixels.ptr, w, h, w);
        self.outputs[0] = .{ .id = 1, .x = 0, .y = 0, .w = w, .h = h, .scale = 1.0, .primary = true };
    }

    pub fn resize(self: *Wasm, w: u32, h: u32) void {
        const new_pixels = self.allocator.realloc(self.pixels, @as(usize, w) * h) catch return;
        self.pixels = new_pixels;
        self.rebuild(w, h);
    }

    pub fn deinit(self: *Wasm) void {
        self.allocator.free(self.pixels);
    }

    pub fn info(ptr: *anyopaque) host_mod.Info {
        const self: *Wasm = @ptrCast(@alignCast(ptr));
        return .{
            .backend = "wasm",
            .pitch = self.surface.pitch_px * 4,
            .outputs = &self.outputs,
            // No real filesystem — fs_wasm.zig keys localStorage entries
            // by these as plain path prefixes, not real directories.
            .paths = .{ .config = "/config/aster", .data = "/data/aster", .home = "/" },
            .caps = .{ .clock = true, .spawn = false, .damage = false, .inject = build_options.conformance },
        };
    }

    pub fn surfaceFn(ptr: *anyopaque) *Surface {
        const self: *Wasm = @ptrCast(@alignCast(ptr));
        return &self.surface;
    }

    // Every browser has a real wall clock — matches info()'s
    // `caps.clock = true` above, per spec/host-contract.md's "the two
    // must agree".
    pub fn clock(ptr: *anyopaque) ?host_mod.Clock {
        _ = ptr;
        return .{
            .unix_ms = @intFromFloat(js_wall_clock_ms()),
            .utc_offset_min = js_utc_offset_min(),
        };
    }

    extern "aster" fn js_present(ptr: [*]const u32, len: usize, w: u32, h: u32) void;

    pub fn present(ptr: *anyopaque) void {
        const self: *Wasm = @ptrCast(@alignCast(ptr));
        js_present(self.pixels.ptr, self.pixels.len, self.surface.w, self.surface.h);
    }

    // aster.frame() only ever calls host.wait(0) (ADR-002) — a real
    // nonzero-timeout block only happens via the conformance suite's own
    // 04_events.lua, which requires host.wait(50) to actually take ~50ms.
    // There is no thread to block on wasm without SharedArrayBuffer +
    // Atomics.wait (real machinery this backend doesn't otherwise need),
    // so this busy-waits on the same clock host.now_ms() reads instead —
    // it blocks the JS thread for the duration, which is fine for a
    // conformance run and never reached in normal operation.
    pub fn wait(ptr: *anyopaque, timeout_ms: i32) ?host_mod.Event {
        const self: *Wasm = @ptrCast(@alignCast(ptr));
        if (timeout_ms <= 0) return self.popPending();
        const deadline = fs.nowMs() + timeout_ms;
        while (true) {
            if (self.popPending()) |ev| return ev;
            if (fs.nowMs() >= deadline) return null;
        }
    }

    fn popPending(self: *Wasm) ?host_mod.Event {
        if (self.pending_len == 0) return null;
        const slot = self.pending_head;
        self.pending_head = (self.pending_head + 1) % max_pending;
        self.pending_len -= 1;
        return self.pending[slot].toEvent();
    }

    const max_pending = 64;

    const PendingEvent = struct {
        tag: host_mod.EventTag,
        key: [32]u8 = undefined,
        key_len: u8 = 0,
        text: [64]u8 = undefined,
        text_len: u8 = 0,
        mods: host_mod.Mods = .{},
        x: i32 = 0,
        y: i32 = 0,
        dx: i32 = 0,
        dy: i32 = 0,
        button: host_mod.MouseButton = .left,
        w: u32 = 0,
        h: u32 = 0,
        focused: bool = false,

        fn toEvent(self: *const PendingEvent) host_mod.Event {
            return switch (self.tag) {
                .key_down => .{ .key_down = .{ .key = self.key[0..self.key_len], .mods = self.mods } },
                .key_up => .{ .key_up = .{ .key = self.key[0..self.key_len], .mods = self.mods } },
                .text => .{ .text = .{ .text = self.text[0..self.text_len] } },
                .mouse_move => .{ .mouse_move = .{ .x = self.x, .y = self.y, .dx = self.dx, .dy = self.dy } },
                .mouse_down => .{ .mouse_down = .{ .x = self.x, .y = self.y, .button = self.button } },
                .mouse_up => .{ .mouse_up = .{ .x = self.x, .y = self.y, .button = self.button } },
                .scroll => .{ .scroll = .{ .x = self.x, .y = self.y, .dx = self.dx, .dy = self.dy } },
                .resize => .{ .resize = .{ .w = self.w, .h = self.h } },
                .focus => .{ .focus = .{ .focused = self.focused } },
                .quit => .{ .quit = .{} },
            };
        }
    };

    fn push(self: *Wasm, ev: PendingEvent) void {
        if (self.pending_len >= max_pending) return; // drop oldest-preserving: just refuse new ones
        const slot = (self.pending_head + self.pending_len) % max_pending;
        self.pending[slot] = ev;
        self.pending_len += 1;
    }

    // conformance builds only (host-contract.md's "Events" section,
    // caps.inject) — pushes straight into the same queue real JS-sourced
    // events use, exactly like SDL backend's inject() does with its own
    // internal queue instead of SDL_PushEvent (ADR-009).
    fn inject(ptr: *anyopaque, ev: host_mod.Event) void {
        const self: *Wasm = @ptrCast(@alignCast(ptr));
        var stored: PendingEvent = .{ .tag = std.meta.activeTag(ev) };
        switch (ev) {
            .key_down => |e| {
                stored.key_len = @intCast(@min(e.key.len, stored.key.len));
                @memcpy(stored.key[0..stored.key_len], e.key[0..stored.key_len]);
                stored.mods = e.mods;
            },
            .key_up => |e| {
                stored.key_len = @intCast(@min(e.key.len, stored.key.len));
                @memcpy(stored.key[0..stored.key_len], e.key[0..stored.key_len]);
                stored.mods = e.mods;
            },
            .text => |e| {
                stored.text_len = @intCast(@min(e.text.len, stored.text.len));
                @memcpy(stored.text[0..stored.text_len], e.text[0..stored.text_len]);
            },
            .mouse_move => |e| {
                stored.x = e.x;
                stored.y = e.y;
                stored.dx = e.dx;
                stored.dy = e.dy;
            },
            .mouse_down => |e| {
                stored.x = e.x;
                stored.y = e.y;
                stored.button = e.button;
            },
            .mouse_up => |e| {
                stored.x = e.x;
                stored.y = e.y;
                stored.button = e.button;
            },
            .scroll => |e| {
                stored.x = e.x;
                stored.y = e.y;
                stored.dx = e.dx;
                stored.dy = e.dy;
            },
            .resize => |e| {
                self.resize(e.w, e.h);
                stored.w = e.w;
                stored.h = e.h;
            },
            .focus => |e| stored.focused = e.focused,
            .quit => {},
        }
        self.push(stored);
    }

    pub fn backend(self: *Wasm) host_mod.Backend {
        return .{
            .ptr = self,
            .infoFn = info,
            .surfaceFn = surfaceFn,
            .presentFn = present,
            .waitFn = wait,
            .clockFn = clock,
            .injectFn = if (build_options.conformance) inject else null,
        };
    }

    // ---- pushed from JS (src/backends/wasm/glue.js) ---------------------

    pub fn pushKeyDown(self: *Wasm, key: []const u8, mods: host_mod.Mods) void {
        var ev: PendingEvent = .{ .tag = .key_down, .mods = mods };
        ev.key_len = @intCast(@min(key.len, ev.key.len));
        @memcpy(ev.key[0..ev.key_len], key[0..ev.key_len]);
        self.push(ev);
    }
    pub fn pushKeyUp(self: *Wasm, key: []const u8, mods: host_mod.Mods) void {
        var ev: PendingEvent = .{ .tag = .key_up, .mods = mods };
        ev.key_len = @intCast(@min(key.len, ev.key.len));
        @memcpy(ev.key[0..ev.key_len], key[0..ev.key_len]);
        self.push(ev);
    }
    pub fn pushText(self: *Wasm, text: []const u8) void {
        var ev: PendingEvent = .{ .tag = .text };
        ev.text_len = @intCast(@min(text.len, ev.text.len));
        @memcpy(ev.text[0..ev.text_len], text[0..ev.text_len]);
        self.push(ev);
    }
    pub fn pushMouseMove(self: *Wasm, x: i32, y: i32, dx: i32, dy: i32) void {
        self.push(.{ .tag = .mouse_move, .x = x, .y = y, .dx = dx, .dy = dy });
    }
    pub fn pushMouseDown(self: *Wasm, x: i32, y: i32, button: host_mod.MouseButton) void {
        self.push(.{ .tag = .mouse_down, .x = x, .y = y, .button = button });
    }
    pub fn pushMouseUp(self: *Wasm, x: i32, y: i32, button: host_mod.MouseButton) void {
        self.push(.{ .tag = .mouse_up, .x = x, .y = y, .button = button });
    }
    pub fn pushScroll(self: *Wasm, x: i32, y: i32, dx: i32, dy: i32) void {
        self.push(.{ .tag = .scroll, .x = x, .y = y, .dx = dx, .dy = dy });
    }
    pub fn pushResize(self: *Wasm, w: u32, h: u32) void {
        self.resize(w, h);
        self.push(.{ .tag = .resize, .w = w, .h = h });
    }
    pub fn pushFocus(self: *Wasm, focused: bool) void {
        self.push(.{ .tag = .focus, .focused = focused });
    }
    pub fn pushQuit(self: *Wasm) void {
        self.push(.{ .tag = .quit });
    }
};
