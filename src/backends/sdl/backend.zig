//! Backend B1 (spec ASTER-WM.md §A.1): a window on Linux, macOS or Windows.
//! Implements the host.info/surface/present/wait quartet; read/write/list/
//! remove/rename/now_ms/clock/log are shared (src/host/fs.zig).

const std = @import("std");
const build_options = @import("build_options");
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const host_mod = @import("../../host/host.zig");
const surface_mod = @import("../../render/surface.zig");
const Surface = surface_mod.Surface;

pub const Sdl = struct {
    window: *c.SDL_Window,
    pixel_surface: *c.SDL_Surface,
    surface: Surface,
    outputs: [1]host_mod.Output = undefined,
    config_path: [:0]const u8,
    data_path: [:0]const u8,
    home_path: [:0]const u8,
    text_buf: [64]u8 = undefined,
    allocator: std.mem.Allocator,
    pending: [max_pending]PendingEvent = undefined,
    pending_head: usize = 0,
    pending_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map, title: [:0]const u8, w: u32, h: u32) !Sdl {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlInit;
        }

        // SDL3 dropped the x/y position params from SDL_CreateWindow itself;
        // centering is now a separate call.
        const window = c.SDL_CreateWindow(title.ptr, @intCast(w), @intCast(h), c.SDL_WINDOW_RESIZABLE) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlInit;
        };
        _ = c.SDL_SetWindowPosition(window, c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED);
        _ = c.SDL_StartTextInput(window);

        const pixel_surface = c.SDL_CreateSurface(@intCast(w), @intCast(h), c.SDL_PIXELFORMAT_XRGB8888) orelse {
            std.debug.print("SDL_CreateSurface failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlInit;
        };

        const home: []const u8 = environ_map.get("HOME") orelse "/tmp";
        const config_path = try std.fmt.allocPrintSentinel(allocator, "{s}/.config/aster", .{home}, 0);
        const data_path = try std.fmt.allocPrintSentinel(allocator, "{s}/.local/share/aster", .{home}, 0);
        const home_path = try std.fmt.allocPrintSentinel(allocator, "{s}", .{home}, 0);

        var self = Sdl{
            .window = window,
            .pixel_surface = pixel_surface,
            .surface = undefined,
            .config_path = config_path,
            .data_path = data_path,
            .home_path = home_path,
            .allocator = allocator,
        };
        self.rebuildSurface();
        return self;
    }

    fn rebuildSurface(self: *Sdl) void {
        const pixels: [*]u32 = @ptrCast(@alignCast(self.pixel_surface.pixels.?));
        const pitch_px: u32 = @intCast(@divExact(self.pixel_surface.pitch, 4));
        self.surface = Surface.init(pixels, @intCast(self.pixel_surface.w), @intCast(self.pixel_surface.h), pitch_px);
        self.outputs[0] = .{
            .id = 1,
            .x = 0,
            .y = 0,
            .w = @intCast(self.pixel_surface.w),
            .h = @intCast(self.pixel_surface.h),
            .scale = 1.0,
            .primary = true,
        };
    }

    pub fn resize(self: *Sdl, w: u32, h: u32) void {
        c.SDL_DestroySurface(self.pixel_surface);
        self.pixel_surface = c.SDL_CreateSurface(@intCast(w), @intCast(h), c.SDL_PIXELFORMAT_XRGB8888).?;
        self.rebuildSurface();
    }

    pub fn deinit(self: *Sdl) void {
        self.allocator.free(self.config_path);
        self.allocator.free(self.data_path);
        self.allocator.free(self.home_path);
        c.SDL_DestroySurface(self.pixel_surface);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn info(ptr: *anyopaque) host_mod.Info {
        const self: *Sdl = @ptrCast(@alignCast(ptr));
        return .{
            .backend = "sdl",
            .pitch = self.surface.pitch_px * 4,
            .outputs = &self.outputs,
            .paths = .{ .config = self.config_path, .data = self.data_path, .home = self.home_path },
            .caps = .{ .clock = true, .spawn = false, .damage = false, .inject = build_options.conformance },
        };
    }

    pub fn surfaceFn(ptr: *anyopaque) *Surface {
        const self: *Sdl = @ptrCast(@alignCast(ptr));
        return &self.surface;
    }

    pub fn present(ptr: *anyopaque) void {
        const self: *Sdl = @ptrCast(@alignCast(ptr));
        const window_surface = c.SDL_GetWindowSurface(self.window);
        _ = c.SDL_BlitSurface(self.pixel_surface, null, window_surface, null);
        _ = c.SDL_UpdateWindowSurface(self.window);
    }

    fn mapScancode(sc: c.SDL_Scancode) ?[:0]const u8 {
        return switch (sc) {
            c.SDL_SCANCODE_A => "a", c.SDL_SCANCODE_B => "b", c.SDL_SCANCODE_C => "c",
            c.SDL_SCANCODE_D => "d", c.SDL_SCANCODE_E => "e", c.SDL_SCANCODE_F => "f",
            c.SDL_SCANCODE_G => "g", c.SDL_SCANCODE_H => "h", c.SDL_SCANCODE_I => "i",
            c.SDL_SCANCODE_J => "j", c.SDL_SCANCODE_K => "k", c.SDL_SCANCODE_L => "l",
            c.SDL_SCANCODE_M => "m", c.SDL_SCANCODE_N => "n", c.SDL_SCANCODE_O => "o",
            c.SDL_SCANCODE_P => "p", c.SDL_SCANCODE_Q => "q", c.SDL_SCANCODE_R => "r",
            c.SDL_SCANCODE_S => "s", c.SDL_SCANCODE_T => "t", c.SDL_SCANCODE_U => "u",
            c.SDL_SCANCODE_V => "v", c.SDL_SCANCODE_W => "w", c.SDL_SCANCODE_X => "x",
            c.SDL_SCANCODE_Y => "y", c.SDL_SCANCODE_Z => "z",
            c.SDL_SCANCODE_0 => "0", c.SDL_SCANCODE_1 => "1", c.SDL_SCANCODE_2 => "2",
            c.SDL_SCANCODE_3 => "3", c.SDL_SCANCODE_4 => "4", c.SDL_SCANCODE_5 => "5",
            c.SDL_SCANCODE_6 => "6", c.SDL_SCANCODE_7 => "7", c.SDL_SCANCODE_8 => "8",
            c.SDL_SCANCODE_9 => "9",
            c.SDL_SCANCODE_SPACE => "space", c.SDL_SCANCODE_RETURN => "enter",
            c.SDL_SCANCODE_ESCAPE => "escape", c.SDL_SCANCODE_TAB => "tab",
            c.SDL_SCANCODE_BACKSPACE => "backspace", c.SDL_SCANCODE_DELETE => "delete",
            c.SDL_SCANCODE_INSERT => "insert",
            c.SDL_SCANCODE_UP => "up", c.SDL_SCANCODE_DOWN => "down",
            c.SDL_SCANCODE_LEFT => "left", c.SDL_SCANCODE_RIGHT => "right",
            c.SDL_SCANCODE_HOME => "home", c.SDL_SCANCODE_END => "end",
            c.SDL_SCANCODE_PAGEUP => "pageup", c.SDL_SCANCODE_PAGEDOWN => "pagedown",
            c.SDL_SCANCODE_F1 => "f1", c.SDL_SCANCODE_F2 => "f2", c.SDL_SCANCODE_F3 => "f3",
            c.SDL_SCANCODE_F4 => "f4", c.SDL_SCANCODE_F5 => "f5", c.SDL_SCANCODE_F6 => "f6",
            c.SDL_SCANCODE_F7 => "f7", c.SDL_SCANCODE_F8 => "f8", c.SDL_SCANCODE_F9 => "f9",
            c.SDL_SCANCODE_F10 => "f10", c.SDL_SCANCODE_F11 => "f11", c.SDL_SCANCODE_F12 => "f12",
            c.SDL_SCANCODE_MINUS => "minus", c.SDL_SCANCODE_EQUALS => "equals",
            c.SDL_SCANCODE_LEFTBRACKET => "bracketleft", c.SDL_SCANCODE_RIGHTBRACKET => "bracketright",
            c.SDL_SCANCODE_SEMICOLON => "semicolon", c.SDL_SCANCODE_APOSTROPHE => "apostrophe",
            c.SDL_SCANCODE_GRAVE => "grave", c.SDL_SCANCODE_BACKSLASH => "backslash",
            c.SDL_SCANCODE_COMMA => "comma", c.SDL_SCANCODE_PERIOD => "period",
            c.SDL_SCANCODE_SLASH => "slash",
            else => null,
        };
    }

    fn modsFrom(m: c.SDL_Keymod) host_mod.Mods {
        return .{
            .ctrl = (m & c.SDL_KMOD_CTRL) != 0,
            .alt = (m & c.SDL_KMOD_ALT) != 0,
            .shift = (m & c.SDL_KMOD_SHIFT) != 0,
            .super = (m & c.SDL_KMOD_GUI) != 0,
        };
    }

    fn mouseButton(b: u8) host_mod.MouseButton {
        return switch (b) {
            c.SDL_BUTTON_RIGHT => .right,
            c.SDL_BUTTON_MIDDLE => .middle,
            else => .left,
        };
    }

    fn translate(self: *Sdl, ev: c.SDL_Event) ?host_mod.Event {
        return switch (ev.type) {
            c.SDL_EVENT_QUIT => .{ .quit = .{} },
            c.SDL_EVENT_KEY_DOWN => blk: {
                if (ev.key.repeat) break :blk null;
                const key = mapScancode(ev.key.scancode) orelse break :blk null;
                break :blk .{ .key_down = .{ .key = key, .mods = modsFrom(ev.key.mod) } };
            },
            c.SDL_EVENT_KEY_UP => blk: {
                const key = mapScancode(ev.key.scancode) orelse break :blk null;
                break :blk .{ .key_up = .{ .key = key, .mods = modsFrom(ev.key.mod) } };
            },
            c.SDL_EVENT_TEXT_INPUT => blk: {
                const text_slice: []const u8 = std.mem.sliceTo(ev.text.text, 0);
                const n = @min(text_slice.len, self.text_buf.len);
                @memcpy(self.text_buf[0..n], text_slice[0..n]);
                break :blk .{ .text = .{ .text = self.text_buf[0..n] } };
            },
            c.SDL_EVENT_MOUSE_MOTION => .{ .mouse_move = .{
                .x = @intFromFloat(ev.motion.x),
                .y = @intFromFloat(ev.motion.y),
                .dx = @intFromFloat(ev.motion.xrel),
                .dy = @intFromFloat(ev.motion.yrel),
            } },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .mouse_down = .{
                .x = @intFromFloat(ev.button.x),
                .y = @intFromFloat(ev.button.y),
                .button = mouseButton(ev.button.button),
            } },
            c.SDL_EVENT_MOUSE_BUTTON_UP => .{ .mouse_up = .{
                .x = @intFromFloat(ev.button.x),
                .y = @intFromFloat(ev.button.y),
                .button = mouseButton(ev.button.button),
            } },
            c.SDL_EVENT_MOUSE_WHEEL => .{ .scroll = .{
                .x = @intFromFloat(ev.wheel.mouse_x),
                .y = @intFromFloat(ev.wheel.mouse_y),
                .dx = ev.wheel.integer_x,
                .dy = ev.wheel.integer_y,
            } },
            c.SDL_EVENT_WINDOW_RESIZED => blk: {
                self.resize(@intCast(ev.window.data1), @intCast(ev.window.data2));
                break :blk .{ .resize = .{ .w = @intCast(ev.window.data1), .h = @intCast(ev.window.data2) } };
            },
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => .{ .focus = .{ .focused = true } },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => .{ .focus = .{ .focused = false } },
            else => null,
        };
    }

    // Called by main.zig's loop after a frame that returned "idle" — blocks
    // the whole process until an event is available (see B6 in
    // spec/troubleshooting.md for why this must not just dequeue-and-drop).
    // `SDL_WaitEventTimeout(NULL, ms)` waits but leaves the event in SDL's
    // own queue for the next `wait()` call to pick up normally.
    pub fn idleWait(self: *Sdl, timeout_ms: u32) void {
        if (self.pending_len > 0) return;
        _ = c.SDL_WaitEventTimeout(null, @intCast(timeout_ms));
    }

    // host.wait(0) must return nil only when SDL's queue is truly empty —
    // an SDL event we don't map to our vocabulary (SDL_EVENT_WINDOW_SHOWN,
    // _EXPOSED, _MOVED, ...) has to be silently skipped here, not reported
    // as "no event", or aster.frame()'s drain loop stops early and leaves
    // real events queued for a whole extra frame.
    pub fn wait(ptr: *anyopaque, timeout_ms: i32) ?host_mod.Event {
        const self: *Sdl = @ptrCast(@alignCast(ptr));
        if (self.pending_len > 0) {
            const slot = self.pending_head;
            self.pending_head = (self.pending_head + 1) % max_pending;
            self.pending_len -= 1;
            return self.pending[slot].toEvent();
        }
        var ev: c.SDL_Event = undefined;
        const deadline = c.SDL_GetTicks() +| @as(u64, @intCast(@max(timeout_ms, 0)));
        while (true) {
            const got = if (timeout_ms <= 0)
                c.SDL_PollEvent(&ev)
            else blk: {
                const now = c.SDL_GetTicks();
                if (now >= deadline) break :blk false;
                break :blk c.SDL_WaitEventTimeout(&ev, @intCast(deadline - now));
            };
            if (!got) return null;
            if (self.translate(ev)) |translated| return translated;
        }
    }

    // ---- conformance builds only (spec/host-contract.md §9.4) -----------
    //
    // Injected events go into our own small queue instead of through
    // SDL_PushEvent — see spec/troubleshooting.md B5 for why, and ADR-009.

    const max_pending = 32;

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

    fn inject(ptr: *anyopaque, ev: host_mod.Event) void {
        const self: *Sdl = @ptrCast(@alignCast(ptr));
        if (self.pending_len >= max_pending) return;

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
                // Actually reallocate the surface now, same as a real
                // SDL_WINDOWEVENT_RESIZED would via translate() — the
                // queued event just tells Lua it happened.
                self.resize(e.w, e.h);
                stored.w = e.w;
                stored.h = e.h;
            },
            .focus => |e| stored.focused = e.focused,
            .quit => {},
        }

        const slot = (self.pending_head + self.pending_len) % max_pending;
        self.pending[slot] = stored;
        self.pending_len += 1;
    }

    pub fn backend(self: *Sdl) host_mod.Backend {
        return .{
            .ptr = self,
            .infoFn = info,
            .surfaceFn = surfaceFn,
            .presentFn = present,
            .waitFn = wait,
            .injectFn = if (build_options.conformance) inject else null,
        };
    }
};
