-- apps/theme-switcher.lua — Space/Enter cycles the desktop's theme through
-- themes/. Applies immediately; showing a preview before committing is a
-- good first issue, not something this version does.

local aster = require("aster")
local r = require("aster.render")

local TOP_MARGIN = require("aster.wm").default_theme.title_h + require("aster.wm").default_theme.border

local THEME_NAMES = { "default", "nord", "catppuccin-mocha", "gruvbox" }

local M = {}
M.name = "theme-switcher"

function M.key(win, key)
  if key ~= "space" and key ~= "enter" then return end
  local wm = aster.state.wm
  if not wm then return end
  win.state.index = (win.state.index or 1) % #THEME_NAMES + 1
  wm.theme = require("themes." .. THEME_NAMES[win.state.index])
  aster.mark_dirty()
end

function M.draw(win, surface)
  local theme = aster.state.wm and aster.state.wm.theme or require("aster.wm").default_theme
  local oy = win.y + TOP_MARGIN
  local name = THEME_NAMES[win.state.index or 1]

  r.fill_rect(surface, win.x, oy, win.w, win.h - TOP_MARGIN, theme.surface)
  r.text(surface, win.x + 8, oy + 8, "theme: " .. name, theme.text)
  r.text(surface, win.x + 8, oy + 8 + r.line_height() + 4, "space / enter to cycle", theme.text_dim)
end

return M
