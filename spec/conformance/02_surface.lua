-- spec/conformance/02_surface.lua — a write appears; clip is respected;
-- push_clip/pop_clip pair correctly. `get_pixel` is a __native_render-only
-- test hook (not part of the host contract, see src/host/bindings.zig).

local r = require("aster.render")
local s = host.surface()

r.fill_rect(s, 2, 2, 1, 1, 0x123456)
assert(r.get_pixel(s, 2, 2) == 0x123456, "a fill_rect write must be visible at that pixel")

r.fill_rect(s, 0, 0, 10, 10, 0x000000)
r.push_clip(s, 0, 0, 2, 2)
r.fill_rect(s, 0, 0, 10, 10, 0xabcdef)
r.pop_clip(s)
assert(r.get_pixel(s, 1, 1) == 0xabcdef, "inside the clip rect must be painted")
assert(r.get_pixel(s, 5, 5) == 0x000000, "outside the clip rect must be untouched")

-- push_clip/pop_clip must nest: popping restores the previous clip, not "no clip"
r.fill_rect(s, 0, 0, 10, 10, 0x000000)
r.push_clip(s, 0, 0, 4, 4)
r.push_clip(s, 0, 0, 1, 1)
r.pop_clip(s)
r.fill_rect(s, 0, 0, 10, 10, 0x111111)
assert(r.get_pixel(s, 2, 2) == 0x111111, "after one pop, the outer clip (4x4) should still apply")
assert(r.get_pixel(s, 5, 5) == 0x000000, "outside the restored outer clip must stay untouched")
r.pop_clip(s)

-- clip_depth/restore_clip (see B32 in spec/troubleshooting.md): the
-- primitives r.clipped is built on. restore_clip only ever pops down to
-- the given depth, it never fabricates a push, so calling it with the
-- current depth (or deeper) is a no-op.
assert(r.clip_depth(s) == 0, "a fresh surface has clip depth 0")
r.push_clip(s, 0, 0, 4, 4)
r.push_clip(s, 0, 0, 2, 2)
assert(r.clip_depth(s) == 2, "two push_clip calls raise depth to 2")
r.restore_clip(s, 1)
assert(r.clip_depth(s) == 1, "restore_clip(1) unwinds exactly one level")
r.fill_rect(s, 0, 0, 10, 10, 0x222222)
assert(r.get_pixel(s, 3, 3) == 0x222222, "after restore_clip(1), the 4x4 clip (not the popped 2x2) must apply")
assert(r.get_pixel(s, 5, 5) == 0x000000, "outside the restored 4x4 clip must stay untouched")
r.restore_clip(s, 0)
assert(r.clip_depth(s) == 0, "restore_clip(0) unwinds back to the base clip")
r.restore_clip(s, 5)
assert(r.clip_depth(s) == 0, "restore_clip with a depth deeper than current must be a no-op, not push")

-- r.clipped (lua/aster/render.lua) must restore the depth it found even
-- when fn itself calls pop_clip an extra time — the actual M6 finding
-- (B32): the pre-fix `push_clip; pcall(fn); pop_clip` shape left this
-- silently corrupted because the final pop_clip became a no-op.
r.clipped(s, 0, 0, 4, 4, function()
  r.pop_clip(s) -- escapes the clip this call just pushed
  r.fill_rect(s, 0, 0, 10, 10, 0xff0000)
end)
assert(r.clip_depth(s) == 0, "r.clipped must restore clip depth to what it found, even after fn escapes it")
r.fill_rect(s, 0, 0, 10, 10, 0x000000)
r.push_clip(s, 0, 0, 2, 2)
local ok = pcall(function()
  r.clipped(s, 0, 0, 4, 4, function() r.pop_clip(s) end)
end)
assert(ok, "clipped must not itself error on an unbalanced fn")
assert(r.clip_depth(s) == 1, "clipped nested inside another clip must restore to that outer depth (1), not 0")
r.pop_clip(s)

-- fill_rect/round_rect's optional trailing alpha (0-255, default 255 =
-- opaque — every call above this point used the default and must be
-- unaffected).
r.fill_rect(s, 0, 0, 10, 10, 0x000000)
r.fill_rect(s, 0, 0, 10, 10, 0xff0000, 128)
do
  local px = r.get_pixel(s, 5, 5)
  local red = (px >> 16) & 0xff
  assert(red > 0x40 and red < 0xff, "alpha 128 must blend, not clamp to 0 or full color")
end
r.fill_rect(s, 0, 0, 10, 10, 0x123456)
r.fill_rect(s, 0, 0, 10, 10, 0xff0000, 0)
assert(r.get_pixel(s, 5, 5) == 0x123456, "alpha 0 must leave the background untouched")

-- r.bind(s) closes every r.raw drawing/clip function over one surface, so
-- a call site can drop the leading surface argument. Round-tripped
-- through fill_rect + get_pixel, not just "did it not error", since the
-- whole point is that it forwards the real surface.
local g = r.bind(s)
r.fill_rect(s, 0, 0, 10, 10, 0x000000)
g.fill_rect(2, 2, 1, 1, 0xabcdef)
assert(r.get_pixel(s, 2, 2) == 0xabcdef, "r.bind's closure must draw onto the surface it was bound to")
g.push_clip(0, 0, 1, 1)
assert(g.clip_depth() == 1, "a bound function still takes its own (non-surface) arguments normally")
g.pop_clip()

print("02_surface: PASS")
