//! Backend-agnostic pieces of the host contract (spec/host-contract.md):
//! event/info shapes, and the vtable a backend implements. Filesystem, clock
//! and log are the same on every backend and live in fs.zig; info/surface/
//! present/wait are backend-specific and live under src/backends/*.

const Surface = @import("../render/surface.zig").Surface;

pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const EventTag = enum {
    key_down,
    key_up,
    text,
    mouse_move,
    mouse_down,
    mouse_up,
    scroll,
    resize,
    focus,
    quit,
};

pub const MouseButton = enum { left, right, middle };

pub const Event = union(EventTag) {
    key_down: struct { key: []const u8, mods: Mods },
    key_up: struct { key: []const u8, mods: Mods },
    text: struct { text: []const u8 },
    mouse_move: struct { x: i32, y: i32, dx: i32, dy: i32 },
    mouse_down: struct { x: i32, y: i32, button: MouseButton },
    mouse_up: struct { x: i32, y: i32, button: MouseButton },
    scroll: struct { x: i32, y: i32, dx: i32, dy: i32 },
    resize: struct { w: u32, h: u32 },
    focus: struct { focused: bool },
    quit: struct {},
};

pub const Output = struct {
    id: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    scale: f32,
    primary: bool,
};

pub const Caps = struct {
    clock: bool,
    spawn: bool,
    damage: bool,
    inject: bool,
};

pub const Paths = struct {
    config: []const u8,
    data: []const u8,
    home: []const u8,
};

pub const Info = struct {
    backend: []const u8,
    format: []const u8 = "xrgb8888",
    pitch: u32,
    outputs: []const Output,
    paths: Paths,
    caps: Caps,
};

pub const Clock = struct {
    unix_ms: i64,
    utc_offset_min: i32,
};

/// A backend implements exactly this shape. Kept as a plain struct of
/// function pointers (not `anytype`) so bindings.zig has one concrete type
/// to hold regardless of which backend was compiled in.
pub const Backend = struct {
    ptr: *anyopaque,
    infoFn: *const fn (ptr: *anyopaque) Info,
    surfaceFn: *const fn (ptr: *anyopaque) *Surface,
    presentFn: *const fn (ptr: *anyopaque) void,
    waitFn: *const fn (ptr: *anyopaque, timeout_ms: i32) ?Event,
    /// caps.inject only: host._inject(event), spec/conformance/ 04_events.lua
    /// and 07_resize.lua. Only set when build.zig's `conformance` build
    /// option is on (the `aster-conformance` binary) — a release build of
    /// `aster` leaves this null.
    injectFn: ?*const fn (ptr: *anyopaque, ev: Event) void = null,

    pub fn info(self: Backend) Info {
        return self.infoFn(self.ptr);
    }
    pub fn surface(self: Backend) *Surface {
        return self.surfaceFn(self.ptr);
    }
    pub fn present(self: Backend) void {
        self.presentFn(self.ptr);
    }
    pub fn wait(self: Backend, timeout_ms: i32) ?Event {
        return self.waitFn(self.ptr, timeout_ms);
    }
    pub fn inject(self: Backend, ev: Event) bool {
        const f = self.injectFn orelse return false;
        f(self.ptr, ev);
        return true;
    }
};
