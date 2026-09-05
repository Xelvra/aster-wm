-- ~/.config/aster/wm.lua — THIS IS your window manager.
--
-- Not a config file: this code runs, and what it does is what the desktop is.
-- Delete it and you get the built-in default. Rewrite it and you get a different
-- desktop on the same host.
--
-- Super+Shift+R reloads it immediately. Your windows stay open. If this file
-- has a syntax error, the previous version keeps running and you get told
-- which line is wrong — you can't break your session from here.

local aster = require("aster")

-- `adopt`, not `new`: on reload this returns the SAME window manager, keeping
-- your windows, workspaces and focus, and resets only what this file overrides.
local wm = aster.wm.adopt {
  gaps   = { outer = 8, inner = 4 },
  border = 2,
}

wm.theme = {
  background = 0x1e2327,
  accent     = 0xff5544,
  inactive   = 0x3b4248,
  text       = 0xd8dee9,
}

-- Want a different frame? Rewrite this. Super+Shift+R. Done — with your
-- windows still open, still holding whatever was in them.
function wm:draw_frame(win)
  local c = win.focused and self.theme.accent or self.theme.inactive
  aster.render.rect_border(self.surface, win.x, win.y, win.w, win.h, self.border, c)
end

local hello = require("apps.hello-window")

wm:bind("super+q", function() wm:close(aster.state.windows[aster.state.focus]) end)
wm:bind("super+n", function() wm:open { app = hello, title = "hello" } end)
wm:bind("super+shift+r", aster.reload)

if not next(aster.state.windows) then
  wm:open { app = hello, title = "hello" }
end

return wm
