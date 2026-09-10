-- widgets/launcher-button.lua — a bar widget (aster.bar.new's widget
-- contract): an accent-colored square with a ">>" glyph, evoking "open
-- menu" — a direct visual port of aster-os's own bar_render launcher
-- button (its own comment calls ">>" a "double chevron, evokes 'open
-- menu'" — kept as-is here rather than relabeled, since the visual port's
-- whole point is matching aster-os, not improving on it). Clicking it
-- toggles the launcher the same way Super+Space does.

local M = {}

function M.draw(bar, surface, x, y, h)
  local r = require("aster.render")
  local theme = bar.wm.theme
  local size = math.min(20, h - 4)
  local by = y + math.floor((h - size) / 2)
  r.fill_rect(surface, x, by, size, size, theme.accent)
  r.text(surface, x + 2, by + math.floor((size - r.line_height()) / 2), ">>", theme.background)
  return size
end

function M.click(bar)
  if bar.wm.launcher then bar.wm.launcher:toggle() end
end

return M
