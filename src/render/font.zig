//! Glyph cache over ttf.zig (ADR-006): rasterizing a glyph on every frame is
//! the one place text rendering could realistically get slow, so a codepoint
//! is rasterized at most once. `assets/font.ttf` is embedded at build time
//! (`@embedFile`, via the sibling `embedded_font` module), so a missing font
//! is a build error, not something that can happen at runtime; the bitmap
//! fallback (font_data.zig) instead covers the bundled font failing to
//! parse — never fails to boot over a font problem.

const std = @import("std");
const ttf = @import("ttf.zig");
const fs = @import("../host/fs.zig");

const font_bytes = @import("embedded_font").bytes;

// Line height in pixels; chosen to match the bitmap fallback's 16px glyphs
// so window chrome laid out around `line_height()` doesn't jump when the
// font changes.
pub const pixel_height: f32 = 16.0;

pub const CachedGlyph = struct {
    data: []u8,
    w: u32,
    h: u32,
    xoff: i32,
    yoff: i32,
    advance: i32,
    last_used: u64 = 0,
};

const max_cached_glyphs = 512;

var allocator: std.mem.Allocator = undefined;
var loaded_font: ?ttf.Font = null;
var cache: std.AutoHashMapUnmanaged(u32, CachedGlyph) = .empty;
var initialized = false;

// Monotonic "how recently was this glyph used" counter, bumped once per
// glyph() call and stamped onto the entry — see B19 in
// spec/troubleshooting.md for why this replaced an ArrayList reordered on
// every lookup.
var use_clock: u64 = 0;

var cached_ascent_px: i32 = 0;

fn loadFont(bytes: []const u8) void {
    const f = ttf.load(bytes) catch |err| {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "assets/font.ttf failed to parse ({s}) — using bitmap fallback", .{@errorName(err)}) catch "assets/font.ttf failed to parse — using bitmap fallback";
        fs.log(msg);
        return;
    };
    loaded_font = f;
    // ascentPx() is a pure function of the loaded font and the single fixed
    // UI pixel_height — computed once here instead of on every glyph draw
    // (see B19 in spec/troubleshooting.md).
    cached_ascent_px = @intFromFloat(@round(@as(f32, @floatFromInt(f.ascent)) * f.scaleForPixelHeight(pixel_height)));
}

pub fn init(a: std.mem.Allocator) void {
    allocator = a;
    initialized = true;
    loadFont(font_bytes);
}

pub fn isLoaded() bool {
    return loaded_font != null;
}

pub fn lineHeight() u32 {
    return @intFromFloat(@ceil(pixel_height));
}

// Distance in pixels from the top of a text line to the baseline — callers
// draw text with `y` meaning "top of the line" (the bitmap font's
// convention), so this is what shifts the TTF path onto the same baseline.
pub fn ascentPx() i32 {
    if (loaded_font == null) return 0;
    return cached_ascent_px;
}

// Evicts the least-recently-used entry by scanning the whole cache once —
// this only runs when the cache is actually full (at most once per
// max_cached_glyphs new codepoints), unlike the old approach of reordering
// an ArrayList on every single lookup. See B19 in spec/troubleshooting.md.
fn evictLru() void {
    var victim: ?u32 = null;
    var victim_used: u64 = std.math.maxInt(u64);
    var it = cache.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.last_used < victim_used) {
            victim_used = entry.value_ptr.last_used;
            victim = entry.key_ptr.*;
        }
    }
    if (victim) |cp| {
        if (cache.fetchRemove(cp)) |kv| allocator.free(kv.value.data);
    }
}

/// Rasterizes and caches `codepoint`, or returns null if the TTF font isn't
/// loaded (caller should fall back to the bitmap font) or allocation fails.
/// Returns a copy rather than a pointer into the cache: `cache.put` can
/// rehash the underlying map, which would invalidate a `getPtr` result
/// still held by the caller — see B19 in spec/troubleshooting.md.
pub fn glyph(codepoint: u32) ?CachedGlyph {
    if (!initialized) return null;
    const font = loaded_font orelse return null;

    use_clock += 1;

    if (cache.getPtr(codepoint)) |g| {
        g.last_used = use_clock;
        return g.*;
    }

    const bmp = ttf.rasterizeCodepoint(font, allocator, codepoint, pixel_height) catch return null;
    if (cache.count() >= max_cached_glyphs) evictLru();
    const entry = CachedGlyph{
        .data = bmp.data,
        .w = bmp.w,
        .h = bmp.h,
        .xoff = bmp.xoff,
        .yoff = bmp.yoff,
        .advance = bmp.advance,
        .last_used = use_clock,
    };
    cache.put(allocator, codepoint, entry) catch {
        allocator.free(bmp.data);
        return null;
    };
    return entry;
}

/// Frees every cached glyph bitmap plus the cache container itself. Called
/// once at shutdown (main.zig) — without it, every distinct glyph
/// rasterized this run is a real DebugAllocator-flagged leak, not just an
/// idle global.
pub fn deinit() void {
    var it = cache.iterator();
    while (it.next()) |entry| allocator.free(entry.value_ptr.data);
    cache.deinit(allocator);
    cache = .empty;
    use_clock = 0;
    loaded_font = null;
    initialized = false;
}

test "loads the embedded font and rasterizes a glyph" {
    defer deinit();
    init(std.testing.allocator);
    try std.testing.expect(isLoaded());
    const g = glyph('A') orelse return error.TestUnexpectedResult;
    try std.testing.expect(g.w > 0);
    try std.testing.expect(g.h > 0);
    try std.testing.expect(g.advance > 0);
}

test "rasterizes a diacritic outside ASCII" {
    defer deinit();
    init(std.testing.allocator);
    const g = glyph(0xE1) orelse return error.TestUnexpectedResult; // 'á'
    try std.testing.expect(g.w > 0);
    try std.testing.expect(g.h > 0);
}

test "repeated lookups hit the cache (same bitmap, not re-rasterized)" {
    defer deinit();
    init(std.testing.allocator);
    const a = glyph('x') orelse return error.TestUnexpectedResult;
    const b = glyph('x') orelse return error.TestUnexpectedResult;
    // glyph() returns a copy (see B19), so this compares the underlying
    // bitmap data/dimensions, not object identity — a re-rasterized glyph
    // would still hold equal *values* by coincidence, but not the exact
    // same `data` slice (same pointer, same len) a cache hit reuses.
    try std.testing.expectEqual(a.data.ptr, b.data.ptr);
    try std.testing.expectEqual(a.data.len, b.data.len);
    try std.testing.expectEqual(a.w, b.w);
    try std.testing.expectEqual(a.h, b.h);
}

test "a corrupted font fails to parse, and font.glyph()/isLoaded() reflect that" {
    // Exercises ttf.load()'s failure path directly rather than through
    // loadFont(), so this test doesn't call fs.log()/std.debug.print — see
    // B20 in spec/troubleshooting.md for why that's flaky under this
    // machine's `zig build test` test-server protocol. The actual
    // log-and-fall-back behavior (loadFont() itself) is verified by running
    // the real binary against a corrupted assets/font.ttf, not by this
    // unit test.
    defer deinit();
    allocator = std.testing.allocator;
    initialized = true;
    try std.testing.expectError(ttf.LoadError.NotTrueType, ttf.load("this is not a TrueType font"));
    try std.testing.expect(!isLoaded());
    try std.testing.expectEqual(@as(?CachedGlyph, null), glyph('A'));
}

