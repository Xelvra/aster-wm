-- tests/ui/mouse_input.lua — lua/aster/input.lua's mouse handling
-- (mouse_down focuses+raises, a click near the top border starts a drag,
-- mouse_move while dragging moves the window, mouse_up ends it) had zero
-- coverage: every other test drives wm:focus_window()/wm:window_at()
-- directly, never through aster.input.dispatch() the way a real backend
-- event does.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
return aster.wm.adopt { border = 4 }
]])
aster.boot()
local wm = aster.state.wm

local a = wm:open { app = { draw = function() end }, x = 0, y = 0, w = 100, h = 100 }
local b = wm:open { app = { draw = function() end }, x = 200, y = 0, w = 100, h = 100 }

-- Clicking a lets it become focused and topmost even though b was opened
-- (and so raised) last.
aster.input.dispatch({ type = "mouse_down", x = 50, y = 50, button = "left" })
assert(aster.state.focus == a.id, "clicking a window must focus it")
assert(wm:window_at(50, 50) == a, "clicking a window must raise it to the top")

-- A click within `border` pixels of the window's top edge starts a drag;
-- mouse_move then repositions the window keeping the original grab offset.
aster.input.dispatch({ type = "mouse_down", x = 210, y = 1, button = "left" })
assert(aster.state.focus == b.id, "clicking near b's border must also focus it")
aster.input.dispatch({ type = "mouse_move", x = 260, y = 21 })
assert(b.x == 250 and b.y == 20, "dragging must move the window by the grab offset: got " .. b.x .. "," .. b.y)

-- mouse_up ends the drag: further mouse_move must not move the window.
aster.input.dispatch({ type = "mouse_up", button = "left" })
aster.input.dispatch({ type = "mouse_move", x = 500, y = 500 })
assert(b.x == 250 and b.y == 20, "mouse_up must end the drag")

-- A click on empty desktop (no window there) must not crash and must not
-- change focus.
local focus_before = aster.state.focus
aster.input.dispatch({ type = "mouse_down", x = 900, y = 900, button = "left" })
assert(aster.state.focus == focus_before, "clicking empty space must not change focus")

-- A right-click is not handled (only "left" raises/drags) and must not crash.
aster.input.dispatch({ type = "mouse_down", x = 50, y = 50, button = "right" })

print("mouse_input: PASS")
