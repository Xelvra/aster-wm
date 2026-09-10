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

-- Pick a theme from themes/ — nord, catppuccin-mocha, gruvbox, or this
-- one, the built-in default. A theme only needs to list the colors it
-- changes; anything it doesn't set falls back to aster.wm.default_theme.
wm.theme = require("themes.default")

-- No wm:draw_frame override here: aster.wm.default_theme's shipped frame
-- (title bar, close button, rounded border, focus-change animation —
-- lua/aster/wm.lua's default_draw_frame) is what a fresh install shows.
-- Want a different frame? Add a `function wm:draw_frame(win, surface)`
-- here to replace it outright — self.border/self.theme are in scope, and
-- wm:title_bar_rect(win)/wm:close_button_rect(win) give the same geometry
-- input.lua hit-tests, so a custom frame can still keep the close button
-- and drag zone working. Super+Shift+R. Done — with your windows still
-- open, still holding whatever was in them.

local hello = require("apps.hello-window")
local editor = require("apps.editor")
local plasma = require("apps.plasma")
local snake = require("apps.snake")
local calculator = require("apps.calculator")
local theme_switcher = require("apps.theme-switcher")

-- The bar: a slot system (lua/aster/bar.lua) that knows nothing about
-- which widgets exist — these five are ordinary registered widgets, not
-- special-cased by the core (ADR-007's discipline, applied to widgets too).
-- Order is left-to-right (launcher button, clock, workspaces, active
-- window title, sysmon), matching aster-os's own bar layout — the active-
-- window widget draws itself centered on the whole screen regardless of
-- where this puts it in the flow (widgets/active-window-widget.lua).
wm.bar = aster.bar.new(wm, {
  height = 28,
  -- Every require() here is parenthesized to truncate it to one value —
  -- require() actually returns two, and Lua spreads a call's full return
  -- list into a table constructor when it's the LAST element (see B36 in
  -- spec/troubleshooting.md). Parenthesizing all of them, not just
  -- whichever happens to be last today, means adding a widget after this
  -- one can't silently reintroduce the bug.
  widgets = {
    (require("widgets.launcher-button")),
    (require("widgets.clock-widget")),
    (require("widgets.workspace-widget")),
    (require("widgets.active-window-widget")),
    (require("widgets.sysmon-widget")),
  },
})

-- The launcher: Super+Space toggles it, entries are registered here, not
-- known to lua/aster/launcher.lua itself (same ADR-007 discipline as the
-- bar's widgets above).
wm.launcher = aster.launcher.new(wm)
wm.launcher:register { title = "hello window", open = function() wm:open { app = hello, title = "hello" } end }
wm.launcher:register {
  title = "edit wm.lua",
  open = function()
    local config_path = aster.state.info.paths.config .. "/wm.lua"
    wm:open { app = editor, title = config_path, state = { path = config_path } }
  end,
}
wm.launcher:register { title = "plasma", open = function() wm:open { app = plasma, title = "plasma" } end }
wm.launcher:register { title = "snake", open = function() wm:open { app = snake, title = "snake" } end }
wm.launcher:register { title = "calculator", open = function() wm:open { app = calculator, title = "calculator", w = 212, h = 254 } end }
wm.launcher:register { title = "theme switcher", open = function() wm:open { app = theme_switcher, title = "theme", w = 240, h = 120 } end }

wm:bind("super+space", function() wm.launcher:toggle() end)
wm:bind("super+q", function() wm:close(aster.state.windows[aster.state.focus]) end)
wm:bind("super+n", function() wm:open { app = hello, title = "hello" } end)
-- Edit this very file: Ctrl+S in the editor writes it, the mtime watch
-- (lua/aster/loop.lua) picks it up within a second, and reloads it —
-- with your other windows still open. This is live-edit.gif.
local config_path = aster.state.info.paths.config .. "/wm.lua"
wm:bind("super+z", function() wm:open { app = editor, title = config_path, state = { path = config_path } } end)
-- Reload itself (Super+Shift+R) is core-level, not a binding you make here
-- (lua/aster/input.lua) — it has to work even when this file is broken.

-- Super+1..9 switches workspace; Super+Shift+1..9 moves the focused window
-- there and follows it (spec/keys.md).
for i = 1, 9 do
  wm:bind("super+" .. i, function() wm:goto_workspace(i) end)
  wm:bind("super+shift+" .. i, function()
    local win = aster.state.windows[aster.state.focus]
    if not win then return end
    wm:move_to_workspace(win, i)
    wm:goto_workspace(i)
  end)
end

-- A fresh install opens two windows side by side, in the same 60/40 split
-- aster-os's tiling layout_pass gave a freshly-started desktop with two
-- windows. Real tiling stays out of scope for now (every window here is
-- still `floating`, positioned by plain x/y/w/h — deferred, not rejected:
-- spec/adr/016-every-window-floats-tiling-is-deferred.md)
-- — this just seeds the same static geometry a live tiler would have
-- produced, so there's something to Alt-drag between and to demonstrate
-- switching focus with, without building the engine that keeps it there.
-- Two different apps, not two copies of one — plasma on the right so a
-- fresh desktop visibly proves the renderer is live (animating) without
-- having to open the launcher first.
--
-- `gaps.inner` is a real gap here — background between the two windows,
-- the same as `gaps.outer` is background between a window and the screen
-- edge — not the border-overlap trick aster-os's own tiling uses (see
-- B43 in spec/troubleshooting.md for why that traded a consistent feel
-- for saving a few pixels): every edge in this layout, touching another
-- window or the screen, gets an actual gap, so there's no seam that
-- reads differently from the rest just because it happens to be between
-- two windows instead of at the screen's own edge.
if not next(aster.state.windows) then
  local out = aster.state.info.outputs[1]
  local gout, gin = wm.gaps.outer, wm.gaps.inner
  local area_x, area_y = gout, wm.bar.height + gout
  local area_w, area_h = out.w - 2 * gout, out.h - wm.bar.height - 2 * gout
  local w1 = math.floor((area_w - gin) * 0.6)
  local w2 = (area_w - gin) - w1
  wm:open {
    app = hello, title = "hello",
    x = area_x, y = area_y, w = w1, h = area_h,
  }
  wm:open {
    app = plasma, title = "plasma",
    x = area_x + w1 + gin, y = area_y, w = w2, h = area_h,
  }
end

return wm
