-- apps/plasma.lua — an animated color field: the cheapest possible proof
-- that the renderer is actually live every frame, not a static screenshot.
-- "Per pixel" isn't literally on offer from Lua (host.* has no setPixel —
-- only fill_rect/round_rect/etc, one native call each), so this fills a
-- coarse grid of small cells instead; still visibly, continuously alive.

local r = require("aster.render")

local M = {}
M.name = "plasma"

-- Same reasoning as apps/editor.lua's TOP_MARGIN: draw(win, surface) has
-- no wm/theme reference, so this assumes the default theme's title bar
-- height to keep the field's top row out from under it.
local TOP_MARGIN = require("aster.wm").default_theme.title_h + require("aster.wm").default_theme.border
local CELL = 10

-- Always redraw: this IS the shape of app (tick returning true every
-- frame) that main.zig's frame limiter (spec/troubleshooting.md B34)
-- exists to keep from pinning a core.
function M.tick()
  return true
end

function M.draw(win, surface)
  local t = host.now_ms() / 300
  local oy = win.y + TOP_MARGIN
  local cols = math.ceil(win.w / CELL)
  local rows = math.ceil((win.h - TOP_MARGIN) / CELL)
  for cy = 0, rows - 1 do
    for cx = 0, cols - 1 do
      local v = math.sin(cx * 0.3 + t) + math.sin(cy * 0.3 + t * 1.3) + math.sin((cx + cy) * 0.2 + t * 0.7)
      local hue = (v + 3) * (math.pi / 3) -- 0..2*pi
      local red = math.floor(128 + 127 * math.sin(hue))
      local green = math.floor(128 + 127 * math.sin(hue + 2.1))
      local blue = math.floor(128 + 127 * math.sin(hue + 4.2))
      local color = (red << 16) | (green << 8) | blue
      r.fill_rect(surface, win.x + cx * CELL, oy + cy * CELL, CELL, CELL, color)
    end
  end
end

return M
