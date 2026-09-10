-- tests/ui/clipped_escape.lua — B32: lua/aster/render.lua's `clipped` must
-- restore the surface's clip stack to the depth it found, even when fn
-- itself calls pop_clip an extra time (escaping its own clip rect early)
-- or push_clip without a matching pop (leaking a level). A plain
-- `push_clip; pcall(fn); pop_clip` — the pre-fix shape — is a no-op once
-- fn has already popped past this call's own push, so the corruption is
-- silent: it only shows up as a sibling draw painting in the wrong place
-- later. fakehost.lua models clip depth the same way
-- src/render/surface.zig does, so this test exercises the same unbalanced
-- shapes as B32's reproduction against the real renderer.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local render = require("aster.render")

local s = host.surface()

-- fn pops one level too many (escapes its own clip, then keeps drawing).
assert(render.clip_depth(s) == 0, "a fresh surface starts at clip depth 0")
render.clipped(s, 0, 0, 10, 10, function()
  assert(render.clip_depth(s) == 1, "clipped must have pushed exactly one level")
  render.pop_clip(s) -- app bug: pops clipped's own level from underneath it
  assert(render.clip_depth(s) == 0, "the app's own pop_clip is honored immediately")
  render.fill_rect(s, 0, 0, 10, 10, 0xff0000) -- draws unclipped for the rest of fn
end)
assert(render.clip_depth(s) == 0, "clipped must restore depth to what it found (0), not leave it corrupted")

-- fn pushes an extra level and never pops it (leaks a level).
render.clipped(s, 0, 0, 10, 10, function()
  render.push_clip(s, 0, 0, 1, 1)
  assert(render.clip_depth(s) == 2, "the app's own push_clip stacks on top of clipped's")
  -- fn returns without popping its own push — clipped must still recover.
end)
assert(render.clip_depth(s) == 0, "clipped must restore depth to what it found (0) even after a leaked push")

-- Nested clipped(): the outer call's depth bookkeeping must survive an
-- inner clipped() whose fn misbehaves the same way.
render.clipped(s, 0, 0, 10, 10, function()
  assert(render.clip_depth(s) == 1, "outer clipped pushed one level")
  render.clipped(s, 1, 1, 2, 2, function()
    assert(render.clip_depth(s) == 2, "inner clipped pushed a second level")
    render.pop_clip(s) -- escapes the inner clip too
  end)
  assert(render.clip_depth(s) == 1, "inner clipped must restore to the outer's depth (1), not 0")
end)
assert(render.clip_depth(s) == 0, "outer clipped must restore to the original depth (0)")

-- fn throwing must still restore the clip depth, not just re-raise.
local ok = pcall(render.clipped, s, 0, 0, 10, 10, function()
  render.pop_clip(s)
  error("boom")
end)
assert(not ok, "the error from fn must still propagate")
assert(render.clip_depth(s) == 0, "a throwing fn must not leave the clip depth corrupted either")

print("clipped_escape: PASS")
