-- lua/aster/render.lua — thin wrapper over the Zig renderer + clip helpers.
-- The renderer never learns what a window is (spec/architecture.md, rule 3);
-- everything here just forwards to __native_render, which Zig registers
-- once at startup (src/host/bindings.zig). Not part of the host contract —
-- it's the shared drawing library, always present regardless of backend.

local native = __native_render

local M = {}

-- No M.blit: it took a second Surface, but nothing in Lua could ever
-- produce one — host.surface() is the only source, always the one on-screen
-- target. An offscreen surface is a new allocation policy the renderer
-- would own; M6 doesn't need one (shadows compose from alpha fill_rect
-- calls, not a second buffer), so the dead API was removed rather than
-- kept unreachable.

-- Every drawing/clip primitive that takes a Surface as its first argument
-- — the set M.bind() closes over. text_width and line_height are
-- deliberately not here: they're font metrics, no surface involved.
M.raw = {
  fill_rect = native.fill_rect,
  round_rect = native.round_rect,
  rect_border = native.rect_border,
  gradient_border = native.gradient_border,
  glyph = native.glyph,
  text = native.text,
  push_clip = native.push_clip,
  pop_clip = native.pop_clip,
  clip_depth = native.clip_depth,
  restore_clip = native.restore_clip,
  get_pixel = native.get_pixel,
}

for name, fn in pairs(M.raw) do
  M[name] = fn
end

M.text_width = native.text_width
M.line_height = native.line_height

-- pcall-safe wrapper: restores the clip to the depth it found, even if fn
-- throws, and even if fn itself called push_clip/pop_clip an unbalanced
-- number of times (see B32 in spec/troubleshooting.md) — a plain pop_clip
-- after the pcall would be a no-op once fn has already popped past this
-- call's own push, silently leaving the surface's clip corrupted for
-- whatever draws next.
function M.clipped(s, x, y, w, h, fn)
  local depth = M.clip_depth(s)
  M.push_clip(s, x, y, w, h)
  local ok, err = pcall(fn)
  M.restore_clip(s, depth)
  if not ok then error(err, 0) end
end
M.raw.clipped = M.clipped

-- bind(surface): closes every M.raw function over one surface, so a ported
-- app (aster-os's own apps have ~100 call sites, all `draw(surface, x, y,
-- ...)`, that would otherwise need a per-call-site rewrite) can do
-- `local g = r.bind(s); g.fill_rect(x, y, w, h, color)` instead. One table
-- per call, not cached: `M.raw` never changes after this module loads, but
-- the surface a caller binds to does, frame to frame.
function M.bind(surface)
  local g = {}
  for name, fn in pairs(M.raw) do
    g[name] = function(...) return fn(surface, ...) end
  end
  return g
end

return M
