-- tests/ui/launcher.lua — lua/aster/launcher.lua: Super+Space toggles it,
-- typed text filters entries, up/down navigates, enter runs the selected
-- entry's open() and closes it, escape closes without running anything,
-- and while it's open a key/text event never reaches the focused window
-- underneath (input.lua's routing order: global bind > launcher > window).

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })

local opened = {}
_G.__register_entries = function(wm)
  wm.launcher = aster.launcher.new(wm)
  wm.launcher:register { title = "hello window", open = function() opened[#opened + 1] = "hello" end }
  wm.launcher:register { title = "calculator", open = function() opened[#opened + 1] = "calc" end }
  wm:bind("super+space", function() wm.launcher:toggle() end)
end

host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
_G.__register_entries(wm)
return wm
]])
aster.boot()
local wm = aster.state.wm

-- A window to prove it never sees keystrokes meant for the launcher.
local win_keys = {}
local win = wm:open { app = { draw = function() end, key = function(w, key) win_keys[#win_keys + 1] = key end } }

assert(not wm.launcher:is_open(), "launcher starts closed")

-- Super+Space (a global keybinding) opens it even though a window is focused.
aster.input.dispatch({ type = "key_down", key = "space", mods = { ctrl = false, alt = false, shift = false, super = true } })
assert(wm.launcher:is_open(), "super+space must open the launcher")
assert(#win_keys == 0, "opening the launcher must not also deliver the keystroke to the focused window")

-- Typing filters; the focused window must not see any of these keys either.
for cp in ("calc"):gmatch(".") do
  aster.input.dispatch({ type = "text", text = cp })
end
local filtered = wm.launcher:filtered()
assert(#filtered == 1 and filtered[1].title == "calculator", "typing must filter to matching entries")
assert(#win_keys == 0, "text routed to the launcher must not reach the focused window")

-- Enter runs the (only, now) filtered entry and closes the launcher.
aster.input.dispatch({ type = "key_down", key = "enter", mods = { ctrl = false, alt = false, shift = false, super = false } })
assert(not wm.launcher:is_open(), "enter must close the launcher")
assert(#opened == 1 and opened[1] == "calc", "enter must run the selected entry's open()")

-- Escape closes without running anything.
wm.launcher:show()
wm.launcher.query = "hello"
aster.input.dispatch({ type = "key_down", key = "escape", mods = { ctrl = false, alt = false, shift = false, super = false } })
assert(not wm.launcher:is_open(), "escape must close the launcher")
assert(#opened == 1, "escape must not run anything")

-- up/down navigation clamps instead of going out of range.
wm.launcher:show()
assert(wm.launcher.selected == 1, "opening resets selection to 1")
wm.launcher:key("up")
assert(wm.launcher.selected == 1, "up at the top must clamp, not go to 0")
wm.launcher:key("down")
wm.launcher:key("down")
wm.launcher:key("down")
assert(wm.launcher.selected == 2, "down must clamp at the number of filtered entries (2 here)")

-- A click outside the popup closes it without reaching the window under it.
wm.launcher:show()
local pr = wm.launcher:popup_rect()
aster.input.dispatch({ type = "mouse_down", x = pr.x - 50, y = pr.y - 50, button = "left" })
assert(not wm.launcher:is_open(), "a click outside the popup must close the launcher")
assert(aster.state.focus == win.id, "a click that closed the launcher must not also focus/click a window underneath")

-- With no matches at all, the popup must still be tall enough to fit the
-- "no match" row it draws — the row's own geometry (row_rect(pr, 1),
-- PAD=12/ROW_H=24 mirrored here since they're launcher.lua-internal) is
-- computed the same way whether there are 0 or 8 items, but popup_rect
-- once sized the popup for 0 rows in the empty case.
wm.launcher:show()
wm.launcher.query = "zzz-no-such-entry"
assert(#wm.launcher:filtered() == 0, "query must match nothing")
local pr2 = wm.launcher:popup_rect()
local PAD, ROW_H = 12, 24
local row1_y = pr2.y + PAD + ROW_H * 1
local r = require("aster.render")
assert(pr2.y + pr2.h >= row1_y + r.line_height(),
  "the popup must be tall enough to fit the 'no match' row: popup bottom "
  .. (pr2.y + pr2.h) .. " < row bottom " .. (row1_y + r.line_height()))

-- Clicking a row runs that entry and closes the launcher — the exact
-- behavior B40 (spec/troubleshooting.md) describes as tiled silently
-- broken (Launcher:click referenced row_rect before its own declaration,
-- so every row click was swallowed as "handled" and did nothing).
wm.launcher:show()
wm.launcher.query = ""
local filtered2 = wm.launcher:filtered()
assert(#filtered2 == 2, "an empty query must show both entries")
local pr3 = wm.launcher:popup_rect()
local PAD3, ROW_H3 = 12, 24
local row2_y = pr3.y + PAD3 + ROW_H3 * 2 -- the second row: "calculator"
aster.input.dispatch({ type = "mouse_down", x = pr3.x + 10, y = row2_y + 5, button = "left" })
assert(not wm.launcher:is_open(), "clicking a row must close the launcher")
assert(#opened == 2 and opened[2] == "calc", "clicking a row must run that entry's open()")

print("launcher: PASS")
