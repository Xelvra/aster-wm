//! The renderer's only drawing target. Backends fill in `pixels`/`w`/`h`/`pitch_px`
//! (SDL3 window pixels, a wasm canvas ImageData, a DRM dumb buffer, ...); the
//! renderer never knows or asks which. v1 supports exactly one pixel format,
//! xrgb8888, little-endian, per spec/host-contract.md.

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn intersect(a: Rect, b: Rect) Rect {
        const ax1 = a.x + @as(i32, @intCast(a.w));
        const ay1 = a.y + @as(i32, @intCast(a.h));
        const bx1 = b.x + @as(i32, @intCast(b.w));
        const by1 = b.y + @as(i32, @intCast(b.h));
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(ax1, bx1);
        const y1 = @min(ay1, by1);
        if (x1 <= x0 or y1 <= y0) return .{ .x = x0, .y = y0, .w = 0, .h = 0 };
        return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }
};

pub const max_clip_depth = 8;

pub const Surface = struct {
    pixels: [*]u32,
    w: u32,
    h: u32,
    pitch_px: u32, // in pixels, not bytes
    clip: Rect,
    clip_stack: [max_clip_depth]Rect = undefined,
    clip_depth: u8 = 0,

    pub fn init(pixels: [*]u32, w: u32, h: u32, pitch_px: u32) Surface {
        return .{
            .pixels = pixels,
            .w = w,
            .h = h,
            .pitch_px = pitch_px,
            .clip = .{ .x = 0, .y = 0, .w = w, .h = h },
        };
    }

    pub fn pushClip(self: *Surface, r: Rect) void {
        if (self.clip_depth >= max_clip_depth) return;
        self.clip_stack[self.clip_depth] = self.clip;
        self.clip_depth += 1;
        self.clip = self.clip.intersect(r);
    }

    pub fn popClip(self: *Surface) void {
        if (self.clip_depth == 0) return;
        self.clip_depth -= 1;
        self.clip = self.clip_stack[self.clip_depth];
    }

    pub fn clipDepth(self: *const Surface) u8 {
        return self.clip_depth;
    }

    // Unwinds the clip stack back to `depth`, one popClip() at a time — see
    // B32 in spec/troubleshooting.md. `depth` greater than or equal to the
    // current depth is a no-op: this only ever pops, it can't fabricate
    // pushes that were never made.
    pub fn restoreClip(self: *Surface, depth: u32) void {
        while (@as(u32, self.clip_depth) > depth) self.popClip();
    }

    pub inline fn setPixel(self: *Surface, x: i32, y: i32, color: u32) void {
        if (x < self.clip.x or y < self.clip.y) return;
        if (x >= self.clip.x + @as(i32, @intCast(self.clip.w))) return;
        if (y >= self.clip.y + @as(i32, @intCast(self.clip.h))) return;
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return;
        self.pixels[@as(usize, @intCast(y)) * self.pitch_px + @as(usize, @intCast(x))] = color;
    }

    pub inline fn getPixel(self: *const Surface, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return 0;
        return self.pixels[@as(usize, @intCast(y)) * self.pitch_px + @as(usize, @intCast(x))];
    }
};
