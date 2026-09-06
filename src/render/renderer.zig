//! The shared drawing library compiled into every backend. Operates on a
//! `Surface`; it never knows what a window is (spec/architecture.md, rule 3).
//! Color is a plain 0xRRGGBB value; xrgb8888 packing happens here, once.

const std = @import("std");
const surface_mod = @import("surface.zig");
const font_data = @import("font_data.zig");
const font = @import("font.zig");

pub const Surface = surface_mod.Surface;
pub const Rect = surface_mod.Rect;

pub const glyph_width = font_data.glyph_width;
pub const glyph_height = font_data.glyph_height;

// ADR-006: called once, at boot, before any drawing. Until this runs (e.g.
// the unit-test binary, which never calls main()), font.glyph() reports
// "not loaded" and every text draw uses the bitmap fallback below.
pub fn initFont(allocator: std.mem.Allocator) void {
    font.init(allocator);
}

pub fn deinitFont() void {
    font.deinit();
}

fn pack(color: u32) u32 {
    return color & 0x00ffffff;
}

fn blendPixel(s: *Surface, x: i32, y: i32, color: u32, coverage: u8) void {
    if (coverage == 0) return;
    if (coverage == 255) {
        s.setPixel(x, y, pack(color));
        return;
    }
    const bg = s.getPixel(x, y);
    const a: u32 = coverage;
    const inv: u32 = 255 - a;
    const cr = (color >> 16) & 0xff;
    const cg = (color >> 8) & 0xff;
    const cb = color & 0xff;
    const br = (bg >> 16) & 0xff;
    const bgn = (bg >> 8) & 0xff;
    const bb = bg & 0xff;
    const r = (cr * a + br * inv) / 255;
    const g = (cg * a + bgn * inv) / 255;
    const b = (cb * a + bb * inv) / 255;
    s.setPixel(x, y, (r << 16) | (g << 8) | b);
}

pub fn fillRect(s: *Surface, x: i32, y: i32, w: u32, h: u32, color: u32) void {
    const c = pack(color);
    // Clip up front rather than visiting every pixel of the requested rect
    // and rejecting most of them one at a time in setPixel: a background
    // fill clipped to a small window is the common case this avoids being
    // needlessly quadratic-feeling across every window on screen.
    const clipped = s.clip.intersect(.{ .x = x, .y = y, .w = w, .h = h });
    if (clipped.w == 0 or clipped.h == 0) return;
    var row: i32 = clipped.y;
    const y_end = clipped.y + @as(i32, @intCast(clipped.h));
    while (row < y_end) : (row += 1) {
        var col: i32 = clipped.x;
        const x_end = clipped.x + @as(i32, @intCast(clipped.w));
        while (col < x_end) : (col += 1) {
            s.setPixel(col, row, c);
        }
    }
}

pub fn rectBorder(s: *Surface, x: i32, y: i32, w: u32, h: u32, thickness: u32, color: u32) void {
    const t: i32 = @intCast(thickness);
    fillRect(s, x, y, w, thickness, color); // top
    fillRect(s, x, y + @as(i32, @intCast(h)) - t, w, thickness, color); // bottom
    fillRect(s, x, y, thickness, h, color); // left
    fillRect(s, x + @as(i32, @intCast(w)) - t, y, thickness, h, color); // right
}

fn gradientOutline(s: *Surface, x: i32, y: i32, w: u32, h: u32, color_a: u32, color_b: u32) void {
    const ar: i32 = @intCast((color_a >> 16) & 0xff);
    const ag: i32 = @intCast((color_a >> 8) & 0xff);
    const ab: i32 = @intCast(color_a & 0xff);
    const br: i32 = @intCast((color_b >> 16) & 0xff);
    const bg: i32 = @intCast((color_b >> 8) & 0xff);
    const bb: i32 = @intCast(color_b & 0xff);
    const perim: i32 = @intCast(2 * (w + h));
    var pos: i32 = 0;

    const gradAt = struct {
        fn f(p: i32, total: i32, r0: i32, g0: i32, b0: i32, r1: i32, g1: i32, b1: i32) u32 {
            if (total <= 0) return @intCast((r0 << 16) | (g0 << 8) | b0);
            const t = @divTrunc(p * 255, total);
            const r = r0 + @divTrunc((r1 - r0) * t, 255);
            const g = g0 + @divTrunc((g1 - g0) * t, 255);
            const b = b0 + @divTrunc((b1 - b0) * t, 255);
            return @as(u32, @intCast(r)) << 16 | @as(u32, @intCast(g)) << 8 | @as(u32, @intCast(b));
        }
    }.f;

    var col: u32 = 0;
    while (col < w) : (col += 1) {
        s.setPixel(x + @as(i32, @intCast(col)), y, gradAt(pos, perim, ar, ag, ab, br, bg, bb));
        pos += 1;
    }
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        s.setPixel(x + @as(i32, @intCast(w)) - 1, y + @as(i32, @intCast(row)), gradAt(pos, perim, ar, ag, ab, br, bg, bb));
        pos += 1;
    }
    col = w;
    while (col > 0) : (col -= 1) {
        s.setPixel(x + @as(i32, @intCast(col)) - 1, y + @as(i32, @intCast(h)) - 1, gradAt(pos, perim, ar, ag, ab, br, bg, bb));
        pos += 1;
    }
    row = h;
    while (row > 0) : (row -= 1) {
        s.setPixel(x, y + @as(i32, @intCast(row)) - 1, gradAt(pos, perim, ar, ag, ab, br, bg, bb));
        pos += 1;
    }
}

pub fn gradientBorder(s: *Surface, x: i32, y: i32, w: u32, h: u32, thickness: u32, color_a: u32, color_b: u32) void {
    // Nests the single-pixel gradient outline inward `thickness` times so
    // the argument actually changes the drawn result (see B21 in
    // spec/troubleshooting.md).
    var t: u32 = 0;
    while (t < thickness and w > 2 * t and h > 2 * t) : (t += 1) {
        gradientOutline(s, x + @as(i32, @intCast(t)), y + @as(i32, @intCast(t)), w - 2 * t, h - 2 * t, color_a, color_b);
    }
}

pub fn roundRect(s: *Surface, x: i32, y: i32, w: u32, h: u32, radius: u32, color: u32) void {
    const c = pack(color);
    const r: i32 = @intCast(radius);
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    var row: i32 = 0;
    while (row < hi) : (row += 1) {
        var col: i32 = 0;
        while (col < wi) : (col += 1) {
            const dx = if (col < r) r - col else if (col >= wi - r) col - (wi - r - 1) else 0;
            const dy = if (row < r) r - row else if (row >= hi - r) row - (hi - r - 1) else 0;
            if (dx != 0 and dy != 0) {
                if (dx * dx + dy * dy > r * r) continue;
            }
            s.setPixel(x + col, y + row, c);
        }
    }
}

pub fn blit(s: *Surface, src: *const Surface, dst_x: i32, dst_y: i32) void {
    var row: u32 = 0;
    while (row < src.h) : (row += 1) {
        var col: u32 = 0;
        while (col < src.w) : (col += 1) {
            s.setPixel(dst_x + @as(i32, @intCast(col)), dst_y + @as(i32, @intCast(row)), src.getPixel(@intCast(col), @intCast(row)));
        }
    }
}

fn drawGlyphRowBitmap(s: *Surface, x: i32, y: i32, codepoint: u32, color: u32) void {
    const c = pack(color);
    const rows = font_data.glyph(codepoint);
    var row: u32 = 0;
    while (row < glyph_height) : (row += 1) {
        const bits = rows[row];
        var col: u32 = 0;
        while (col < glyph_width) : (col += 1) {
            if ((bits >> @intCast(7 - col)) & 1 != 0) {
                s.setPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), c);
            }
        }
    }
}

// Draws one codepoint with `top_y` as the top of the text line (matching
// the bitmap font's convention, so existing call sites that pace lines by
// lineHeight() don't need to change) and returns the pixel advance to the
// next glyph's pen x.
fn drawCodepoint(s: *Surface, pen_x: i32, top_y: i32, codepoint: u32, color: u32) u32 {
    if (font.glyph(codepoint)) |g| {
        const baseline_y = top_y + font.ascentPx();
        var row: u32 = 0;
        while (row < g.h) : (row += 1) {
            var col: u32 = 0;
            while (col < g.w) : (col += 1) {
                const cov = g.data[row * g.w + col];
                if (cov != 0) {
                    blendPixel(s, pen_x + g.xoff + @as(i32, @intCast(col)), baseline_y + g.yoff + @as(i32, @intCast(row)), color, cov);
                }
            }
        }
        return @intCast(g.advance);
    }
    drawGlyphRowBitmap(s, pen_x, top_y, codepoint, color);
    return glyph_width;
}

fn advanceFor(codepoint: u32) u32 {
    if (font.glyph(codepoint)) |g| return @intCast(g.advance);
    return glyph_width;
}

pub fn drawGlyphRow(s: *Surface, x: i32, y: i32, codepoint: u32, color: u32) void {
    _ = drawCodepoint(s, x, y, codepoint, color);
}

fn nextCodePoint(text: []const u8, i: *usize) u32 {
    const b0 = text[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    var len: usize = 1;
    var cp: u32 = 0;
    if (b0 & 0xe0 == 0xc0) {
        len = 2;
        cp = b0 & 0x1f;
    } else if (b0 & 0xf0 == 0xe0) {
        len = 3;
        cp = b0 & 0x0f;
    } else if (b0 & 0xf8 == 0xf0) {
        len = 4;
        cp = b0 & 0x07;
    } else {
        i.* += 1;
        return 0xfffd;
    }
    if (i.* + len > text.len) {
        i.* += 1;
        return 0xfffd;
    }
    var k: usize = 1;
    while (k < len) : (k += 1) {
        const b = text[i.* + k];
        if (b & 0xc0 != 0x80) {
            i.* += 1;
            return 0xfffd;
        }
        cp = (cp << 6) | (b & 0x3f);
    }
    i.* += len;
    return cp;
}

pub fn drawText(s: *Surface, x: i32, y: i32, text: []const u8, color: u32) void {
    var i: usize = 0;
    var pen_x = x;
    while (i < text.len) {
        const cp = nextCodePoint(text, &i);
        pen_x += @as(i32, @intCast(drawCodepoint(s, pen_x, y, cp, color)));
    }
}

pub fn textWidth(text: []const u8) u32 {
    var i: usize = 0;
    var total: u32 = 0;
    while (i < text.len) {
        const cp = nextCodePoint(text, &i);
        total += advanceFor(cp);
    }
    return total;
}

pub fn lineHeight() u32 {
    if (font.isLoaded()) return font.lineHeight();
    return glyph_height;
}

test "fillRect respects clip" {
    var buf: [16]u32 = [_]u32{0} ** 16;
    var s = Surface.init(&buf, 4, 4, 4);
    s.pushClip(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    fillRect(&s, 0, 0, 4, 4, 0xff0000);
    try std.testing.expectEqual(@as(u32, 0), s.getPixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff0000), s.getPixel(1, 1));
    try std.testing.expectEqual(@as(u32, 0xff0000), s.getPixel(2, 2));
    try std.testing.expectEqual(@as(u32, 0), s.getPixel(3, 3));
}

test "push/pop clip restores previous rect" {
    var buf: [16]u32 = [_]u32{0} ** 16;
    var s = Surface.init(&buf, 4, 4, 4);
    s.pushClip(.{ .x = 1, .y = 1, .w = 2, .h = 2 });
    s.pushClip(.{ .x = 1, .y = 1, .w = 1, .h = 1 });
    s.popClip();
    fillRect(&s, 0, 0, 4, 4, 0x00ff00);
    try std.testing.expectEqual(@as(u32, 0x00ff00), s.getPixel(2, 2));
    try std.testing.expectEqual(@as(u32, 0), s.getPixel(3, 3));
}

test "drawText advances by glyph width" {
    var buf: [64 * 16]u32 = [_]u32{0} ** (64 * 16);
    var s = Surface.init(&buf, 64, 16, 64);
    drawText(&s, 0, 0, "hi", 0xffffff);
    try std.testing.expectEqual(@as(u32, 16), textWidth("hi"));
}
