-- apps/hello-window.lua
--
-- A complete aster app. There is nothing else — no manifest, no registration,
-- no build step. Drop this file in apps/, point a keybinding at it in your
-- wm.lua, hit Ctrl+S.
--
-- Everything the editor, the file browser and the REPL can do, this file can
-- do too. They are apps like this one.

local r = require("aster.render")

local app = {}

app.name = "hello"

-- draw(win, surface) has no wm/theme reference (see apps/editor.lua's own
-- TOP_MARGIN note), so this assumes the default theme's title bar height to
-- keep content out from under it — win.y is the top of the whole frame
-- (lua/aster/wm.lua's title_bar_rect sits at win.y + border), not the top of
-- the content area.
local TOP_MARGIN = require("aster.wm").default_theme.title_h + require("aster.wm").default_theme.border

-- Called every frame your window is visible. Drawing is clipped to the window,
-- so you can't paint over your neighbours even if you try.
function app.draw(win, surface)
  local aster = require("aster")
  local theme = aster.state.wm and aster.state.wm.theme or require("aster.wm").default_theme
  local oy = win.y + TOP_MARGIN
  r.fill_rect(surface, win.x, oy, win.w, win.h - TOP_MARGIN, theme.surface)
  r.text(surface, win.x + 12, oy + 12, "hello, window", theme.text)
  r.text(surface, win.x + 12, oy + 12 + r.line_height(),
         win.state.message or "press any key", theme.text_dim)
end

-- Optional. Global keybindings (lua/aster/input.lua) are checked before any
-- app ever sees a key, the same way i3/sway/awesome grab their own
-- shortcuts first — otherwise a buggy or malicious app could swallow the
-- one keybinding (Super+Q) that closes it. This callback's return value is
-- currently unused.
function app.key(win, key, mods)
  if key == "escape" then
    win.state.message = nil
  else
    win.state.message = "you pressed: " .. key
  end
end

return app
