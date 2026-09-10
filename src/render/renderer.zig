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

// See B34 in spec/troubleshooting.md: a full-screen fillRect (the common
// case for a background redraw) went through setPixel's per-pixel
// bounds-and-clip re-check, ~800k times for a 1024x768 surface — the
// dominant cost in a frame that turned out to be doing almost nothing
// else. `clipped` is already inside both s.clip AND the surface bounds
// (Surface.clip is established as an invariant: it starts as exactly the
// surface's own bounds and every push_clip only ever narrows it further
// via Rect.intersect), so each row can be written with one @memset instead
// of a per-pixel store, and every per-pixel bounds check is redundant.
//
// `alpha` (0-255, 255 = opaque): composing a shadow or a dimmed-inactive-
// window overlay is a handful of fill_rect calls with
// falling alpha in Lua (P3 — the renderer never gets a `shadow()` function,
// that would be policy). 255 keeps the @memset fast path; anything less
// falls back to per-pixel blending, since @memset can't blend against
// whatever is already there.
pub fn fillRect(s: *Surface, x: i32, y: i32, w: u32, h: u32, color: u32, alpha: u8) void {
    const clipped = s.clip.intersect(.{ .x = x, .y = y, .w = w, .h = h });
    if (clipped.w == 0 or clipped.h == 0) return;
    const y_end = clipped.y + @as(i32, @intCast(clipped.h));
    const x_end = clipped.x + @as(i32, @intCast(clipped.w));
    if (alpha == 255) {
        const c = pack(color);
        var row: i32 = clipped.y;
        while (row < y_end) : (row += 1) {
            const row_start = @as(usize, @intCast(row)) * s.pitch_px + @as(usize, @intCast(clipped.x));
            @memset(s.pixels[row_start .. row_start + clipped.w], c);
        }
        return;
    }
    var row: i32 = clipped.y;
    while (row < y_end) : (row += 1) {
        var col: i32 = clipped.x;
        while (col < x_end) : (col += 1) {
            blendPixel(s, col, row, color, alpha);
        }
    }
}

pub fn rectBorder(s: *Surface, x: i32, y: i32, w: u32, h: u32, thickness: u32, color: u32) void {
    const t: i32 = @intCast(thickness);
    fillRect(s, x, y, w, thickness, color, 255); // top
    fillRect(s, x, y + @as(i32, @intCast(h)) - t, w, thickness, color, 255); // bottom
    fillRect(s, x, y, thickness, h, color, 255); // left
    fillRect(s, x + @as(i32, @intCast(w)) - t, y, thickness, h, color, 255); // right
}

// Each of the four edges sweeps the FULL color_a..color_b range over its
// own length, not a slice of one shared perimeter-wide sweep — see B41 in
// spec/troubleshooting.md. The old version walked one continuous a->b
// ramp all the way around (top, then right, then bottom, then left), so
// how much of that ramp any one edge got depended on where it fell in the
// loop, not on that edge's own length: the top edge (walked first) always
// started at pure color_a, while the left edge (walked last) always
// landed in the final sliver near pure color_b — on a window taller than
// it is wide (title bars stack two windows side by side, e.g.), the top/
// bottom edges are a small fraction of the perimeter and the left/right
// edges dominate it, so the left edge in particular could end up nearly
// solid color_b instead of visibly sweeping anything. Two adjacent
// windows' touching edges (one's right border sitting under the other's
// left) would then look nothing alike — one a real gradient, the other
// flat — even though both are "the same" focused-window border.
//
// Each edge below still ends where its clockwise-next neighbour begins
// (top ends at b, right starts at b and ends at a, bottom starts at a and
// ends at b, left starts at b and ends at a matching top's own start) —
// alternating sweep direction per edge keeps all four corners exactly
// continuous, same as the old single-loop version did, without tying any
// edge's visible range to its length.
// `t` is 0..255 along one edge's own length; which of (r0,g0,b0) or
// (r1,g1,b1) the caller passes as that edge's *start* color is what picks
// its sweep direction — never a separate "reversed" flag on top of that,
// which is its own way to end up cancelling itself out.
fn gradAt(t: i32, r0: i32, g0: i32, b0: i32, r1: i32, g1: i32, b1: i32) u32 {
    const r = r0 + @divTrunc((r1 - r0) * t, 255);
    const g = g0 + @divTrunc((g1 - g0) * t, 255);
    const b = b0 + @divTrunc((b1 - b0) * t, 255);
    return @as(u32, @intCast(r)) << 16 | @as(u32, @intCast(g)) << 8 | @as(u32, @intCast(b));
}

// Position `i` (0-based) out of `len` steps along one edge -> 0..255.
// `len <= 1` (a 1px-wide/tall edge) has nothing to divide by; that's just
// this edge's start color, i.e. t = 0.
fn tAt(i: u32, len: u32) i32 {
    if (len <= 1) return 0;
    return @divTrunc(@as(i32, @intCast(i)) * 255, @as(i32, @intCast(len - 1)));
}

fn gradientOutline(s: *Surface, x: i32, y: i32, w: u32, h: u32, color_a: u32, color_b: u32) void {
    const ar: i32 = @intCast((color_a >> 16) & 0xff);
    const ag: i32 = @intCast((color_a >> 8) & 0xff);
    const ab: i32 = @intCast(color_a & 0xff);
    const br: i32 = @intCast((color_b >> 16) & 0xff);
    const bg: i32 = @intCast((color_b >> 8) & 0xff);
    const bb: i32 = @intCast(color_b & 0xff);

    var col: u32 = 0;
    while (col < w) : (col += 1) { // top: a (left) -> b (right)
        s.setPixel(x + @as(i32, @intCast(col)), y, gradAt(tAt(col, w), ar, ag, ab, br, bg, bb));
    }
    var row: u32 = 0;
    while (row < h) : (row += 1) { // right: b (top) -> a (bottom)
        s.setPixel(x + @as(i32, @intCast(w)) - 1, y + @as(i32, @intCast(row)), gradAt(tAt(row, h), br, bg, bb, ar, ag, ab));
    }
    col = w;
    while (col > 0) : (col -= 1) { // bottom: a (right) -> b (left)
        s.setPixel(x + @as(i32, @intCast(col)) - 1, y + @as(i32, @intCast(h)) - 1, gradAt(tAt(w - col, w), ar, ag, ab, br, bg, bb));
    }
    row = h;
    while (row > 0) : (row -= 1) { // left: b (bottom) -> a (top)
        s.setPixel(x, y + @as(i32, @intCast(row)) - 1, gradAt(tAt(h - row, h), br, bg, bb, ar, ag, ab));
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

// A hard `dx*dx+dy*dy > r*r` cutoff drew a jagged, aliased corner — the
// first thing anyone would see once window frames actually use this.
// Each corner pixel's coverage is a signed distance from the circle
// boundary at radius `r + 0.5` (so the "opaque up to here, transparent
// past here" edge sits mid-pixel, the usual AA convention), clamped to a
// one-pixel-wide fade — cheap (no supersampling) and enough at UI text
// sizes. `alpha` composes with the caller's requested alpha the same way
// fillRect's does.
//
// Clips up front like fillRect (B34 in spec/troubleshooting.md) instead of
// visiting every pixel of the full w*h rect and rejecting most of them one
// at a time: lua/aster/wm.lua's default_draw_frame draws a rounded border
// as a ring by calling this four times, each behind a push_clip narrowed
// to one edge band, so the corner math (which needs the full w/h/radius to
// come out right) still sees the whole rect while the pixels actually
// touched are just that band — without this, each of those four calls
// would cost the full window's pixel count instead of one thin strip's.
pub fn roundRect(s: *Surface, x: i32, y: i32, w: u32, h: u32, radius: u32, color: u32, alpha: u8) void {
    const r: i32 = @intCast(radius);
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    const clipped = s.clip.intersect(.{ .x = x, .y = y, .w = w, .h = h });
    if (clipped.w == 0 or clipped.h == 0) return;
    var py: i32 = clipped.y;
    const y_end = clipped.y + @as(i32, @intCast(clipped.h));
    while (py < y_end) : (py += 1) {
        const row = py - y;
        var px: i32 = clipped.x;
        const x_end = clipped.x + @as(i32, @intCast(clipped.w));
        while (px < x_end) : (px += 1) {
            const col = px - x;
            const dx = if (col < r) r - col else if (col >= wi - r) col - (wi - r - 1) else 0;
            const dy = if (row < r) r - row else if (row >= hi - r) row - (hi - r - 1) else 0;
            if (dx == 0 or dy == 0) {
                blendPixel(s, px, py, color, alpha);
                continue;
            }
            const dist = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
            const edge = @as(f32, @floatFromInt(r)) + 0.5 - dist;
            if (edge <= 0) continue;
            const frac = @min(edge, 1.0);
            const coverage: u8 = @intFromFloat(@as(f32, @floatFromInt(alpha)) * frac);
            blendPixel(s, px, py, color, coverage);
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
    fillRect(&s, 0, 0, 4, 4, 0xff0000, 255);
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
    fillRect(&s, 0, 0, 4, 4, 0x00ff00, 255);
    try std.testing.expectEqual(@as(u32, 0x00ff00), s.getPixel(2, 2));
    try std.testing.expectEqual(@as(u32, 0), s.getPixel(3, 3));
}

test "drawText advances by glyph width" {
    var buf: [64 * 16]u32 = [_]u32{0} ** (64 * 16);
    var s = Surface.init(&buf, 64, 16, 64);
    drawText(&s, 0, 0, "hi", 0xffffff);
    try std.testing.expectEqual(@as(u32, 16), textWidth("hi"));
}

test "fillRect with alpha 255 is opaque, matching the default" {
    var buf: [16]u32 = [_]u32{0} ** 16;
    var s = Surface.init(&buf, 4, 4, 4);
    fillRect(&s, 0, 0, 4, 4, 0xff0000, 255);
    try std.testing.expectEqual(@as(u32, 0xff0000), s.getPixel(0, 0));
}

test "fillRect with alpha 0 leaves the background untouched" {
    var buf: [16]u32 = [_]u32{0} ** 16;
    var s = Surface.init(&buf, 4, 4, 4);
    fillRect(&s, 0, 0, 4, 4, 0x123456, 255);
    fillRect(&s, 0, 0, 4, 4, 0xff0000, 0);
    try std.testing.expectEqual(@as(u32, 0x123456), s.getPixel(0, 0));
}

test "fillRect with partial alpha blends toward the fill color, not past it" {
    var buf: [16]u32 = [_]u32{0} ** 16;
    var s = Surface.init(&buf, 4, 4, 4);
    fillRect(&s, 0, 0, 4, 4, 0x000000, 255); // black background
    fillRect(&s, 0, 0, 4, 4, 0xff0000, 128); // ~50% red over it
    const px = s.getPixel(0, 0);
    const red = (px >> 16) & 0xff;
    try std.testing.expect(red > 0x40 and red < 0xff); // blended, not clamped either way
    try std.testing.expectEqual(@as(u32, 0), px & 0x00ffff); // no green/blue bled in
}

test "roundRect's corner is anti-aliased, not a hard cutoff" {
    // The acceptance test is specifically that the corner pixel right at
    // the circle boundary is an intermediate value between background and
    // fill color, not just one or the other.
    var buf: [64 * 64]u32 = [_]u32{0} ** (64 * 64);
    var s = Surface.init(&buf, 64, 64, 64);
    roundRect(&s, 0, 0, 40, 40, 12, 0xff0000, 255);
    // (0,0) is well outside the radius-12 circle centered around (11,11):
    // fully background. (11,11) is inside: fully the fill color. Scan the
    // diagonal between them for at least one pixel that is neither.
    try std.testing.expectEqual(@as(u32, 0), s.getPixel(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff0000), s.getPixel(11, 11));
    // Scan the whole corner quadrant, not just the diagonal: at radius 12
    // the diagonal's pixel centers (spaced sqrt(2) apart in distance from
    // the corner) happen to step clean over the ~1px AA band, so a
    // diagonal-only scan can miss it by construction, not because AA is
    // broken. A 2D scan can't miss the band the same way.
    var found_partial = false;
    var row: i32 = 0;
    while (row < 12) : (row += 1) {
        var col: i32 = 0;
        while (col < 12) : (col += 1) {
            const px = s.getPixel(col, row);
            if (px != 0 and px != 0xff0000) found_partial = true;
        }
    }
    try std.testing.expect(found_partial);
}

test "gradientBorder: every edge sweeps the full color range on its own, regardless of the rect's aspect ratio" {
    // B41 in spec/troubleshooting.md: the old version walked one
    // continuous gradient around the whole perimeter, so a tall, narrow
    // rect's left/right edges (which dominate that perimeter) barely
    // moved off the color they happened to start near — this rect (4 wide,
    // 40 tall) is exactly that shape. Left and right are the edges that
    // used to break; sampling near each end of each one should now show
    // red at one end and near-black at the other, not two similar shades.
    var buf: [4 * 40]u32 = [_]u32{0} ** (4 * 40);
    var s = Surface.init(&buf, 4, 40, 4);
    gradientBorder(&s, 0, 0, 4, 40, 1, 0xff0000, 0x000000);

    const left_top_red = (s.getPixel(0, 2) >> 16) & 0xff;
    const left_bottom_red = (s.getPixel(0, 37) >> 16) & 0xff;
    try std.testing.expect(@max(left_top_red, left_bottom_red) - @min(left_top_red, left_bottom_red) > 150);

    const right_top_red = (s.getPixel(3, 2) >> 16) & 0xff;
    const right_bottom_red = (s.getPixel(3, 37) >> 16) & 0xff;
    try std.testing.expect(@max(right_top_red, right_bottom_red) - @min(right_top_red, right_bottom_red) > 150);
}
