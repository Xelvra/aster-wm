-- lua/aster/render.lua — thin wrapper over the Zig renderer + clip helpers.
-- The renderer never learns what a window is (spec/architecture.md, rule 3);
-- everything here just forwards to __native_render, which Zig registers
-- once at startup (src/host/bindings.zig). Not part of the host contract —
-- it's the shared drawing library, always present regardless of backend.

local native = __native_render

local M = {}

M.fill_rect = native.fill_rect
M.round_rect = native.round_rect
M.rect_border = native.rect_border
M.gradient_border = native.gradient_border
M.blit = native.blit
M.glyph = native.glyph
M.text = native.text
M.text_width = native.text_width
M.line_height = native.line_height
M.push_clip = native.push_clip
M.pop_clip = native.pop_clip
M.get_pixel = native.get_pixel

-- pcall-safe wrapper: pops the clip even if fn throws, then re-raises.
function M.clipped(s, x, y, w, h, fn)
  M.push_clip(s, x, y, w, h)
  local ok, err = pcall(fn)
  M.pop_clip(s)
  if not ok then error(err, 0) end
end

-- A table of drawing functions with `s` already bound, so call sites read
-- like g.fill_rect(x, y, w, h, color) instead of repeating the surface.
local bound_names = {
  "fill_rect", "round_rect", "rect_border", "gradient_border", "blit", "glyph", "text",
}

function M.bind(s)
  local g = { text_width = M.text_width, line_height = M.line_height }
  for _, name in ipairs(bound_names) do
    local fn = M[name]
    g[name] = function(...) return fn(s, ...) end
  end
  return g
end

return M
