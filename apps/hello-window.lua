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

-- Called every frame your window is visible. Drawing is clipped to the window,
-- so you can't paint over your neighbours even if you try.
function app.draw(win, surface)
  r.fill_rect(surface, win.x, win.y, win.w, win.h, 0x1e2327)
  r.text(surface, win.x + 12, win.y + 12, "hello, window", 0xd8dee9)
  r.text(surface, win.x + 12, win.y + 12 + r.line_height(),
         win.state.message or "press any key", 0x6a737d)
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
