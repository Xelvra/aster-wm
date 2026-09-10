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
wm.bar = aster.bar.new(wm, { height = 28 })

local a = wm:open { app = { draw = function() end }, x = 0, y = 0, w = 100, h = 100 }
local b = wm:open { app = { draw = function() end }, x = 200, y = 0, w = 100, h = 100 }

-- Clicking a lets it become focused and topmost even though b was opened
-- (and so raised) last.
aster.input.dispatch({ type = "mouse_down", x = 50, y = 50, button = "left" })
assert(aster.state.focus == a.id, "clicking a window must focus it")
assert(wm:window_at(50, 50) == a, "clicking a window must raise it to the top")

-- A click on the window's title bar (border + theme.title_h from the top
-- edge — wm:title_bar_rect, the same geometry the title bar is drawn
-- with) starts a drag; mouse_move then repositions the window keeping the
-- original grab offset.
aster.input.dispatch({ type = "mouse_down", x = 210, y = 10, button = "left" })
assert(aster.state.focus == b.id, "clicking on b's title bar must also focus it")
-- Moved to y=40 (not y=30 as it once was): with wm.bar now set up (below)
-- for the drag-clamp test further down, y=30-10=20 would land above
-- min_y (bar.height=28 - border=4 = 24) and get clamped there instead of
-- testing the plain grab-offset arithmetic this block exists to check —
-- that's what the dedicated clamp test below is for.
aster.input.dispatch({ type = "mouse_move", x = 260, y = 40 })
assert(b.x == 250 and b.y == 30, "dragging must move the window by the grab offset: got " .. b.x .. "," .. b.y)

-- mouse_up ends the drag: further mouse_move must not move the window.
aster.input.dispatch({ type = "mouse_up", button = "left" })
aster.input.dispatch({ type = "mouse_move", x = 500, y = 500 })
assert(b.x == 250 and b.y == 30, "mouse_up must end the drag")

-- A click inside the window body (below the title bar) must focus/raise
-- but not start a drag.
aster.input.dispatch({ type = "mouse_down", x = 20, y = 60, button = "left" })
assert(aster.state.focus == a.id, "clicking a's body must focus it")
aster.input.dispatch({ type = "mouse_move", x = 999, y = 999 })
assert(a.x == 0 and a.y == 0, "a click below the title bar must not start a drag")
aster.input.dispatch({ type = "mouse_up", button = "left" })

-- A click on the close button (wm:close_button_rect, top-right of the
-- title bar) closes the window instead of starting a drag.
local cb = wm:close_button_rect(b)
aster.input.dispatch({ type = "mouse_down", x = cb.x + 1, y = cb.y + 1, button = "left" })
assert(aster.state.windows[b.id] == nil, "clicking the close button must close the window")

-- A click on empty desktop (no window there) must not crash and must not
-- change focus.
local focus_before = aster.state.focus
aster.input.dispatch({ type = "mouse_down", x = 900, y = 900, button = "left" })
assert(aster.state.focus == focus_before, "clicking empty space must not change focus")

-- A right-click is not handled (only "left" raises/drags) and must not crash.
aster.input.dispatch({ type = "mouse_down", x = 50, y = 50, button = "right" })

-- Dragging a window's title bar up above the bar must clamp there — once
-- it's behind the bar there's nothing left to grab (the bar owns clicks
-- in front of it).
do
  a.x, a.y = 0, 100
  aster.input.dispatch({ type = "mouse_down", x = 50, y = 100 + wm.border + 2, button = "left" })
  aster.input.dispatch({ type = "mouse_move", x = 50, y = -500 })
  local min_y = wm.bar.height - wm.border
  assert(a.y == min_y, "dragging up past the bar must clamp win.y to " .. min_y .. ", got " .. a.y)
  aster.input.dispatch({ type = "mouse_up", button = "left" })
end

-- Double-clicking a title bar toggles maximize; a second double-click
-- restores the original geometry.
do
  fake._set_now_ms(0)
  a.x, a.y, a.w, a.h = 10, 100, 100, 100
  local tby = a.y + wm.border + 1
  aster.input.dispatch({ type = "mouse_down", x = 50, y = tby, button = "left" })
  aster.input.dispatch({ type = "mouse_up", button = "left" })
  fake._advance_ms(100) -- well within DOUBLE_CLICK_MS
  aster.input.dispatch({ type = "mouse_down", x = 50, y = tby, button = "left" })
  assert(a.x ~= 10 or a.y ~= 100 or a.w ~= 100 or a.h ~= 100,
    "a double-click on the title bar must maximize the window")
  local maxed = { x = a.x, y = a.y, w = a.w, h = a.h }
  aster.input.dispatch({ type = "mouse_up", button = "left" })

  -- Toggling back: double-click again restores the exact pre-maximize rect.
  fake._advance_ms(100)
  aster.input.dispatch({ type = "mouse_down", x = maxed.x + 5, y = maxed.y + wm.border + 1, button = "left" })
  aster.input.dispatch({ type = "mouse_up", button = "left" })
  fake._advance_ms(100)
  aster.input.dispatch({ type = "mouse_down", x = maxed.x + 5, y = maxed.y + wm.border + 1, button = "left" })
  assert(a.x == 10 and a.y == 100 and a.w == 100 and a.h == 100,
    "a second double-click must restore the pre-maximize geometry")
  aster.input.dispatch({ type = "mouse_up", button = "left" })
end

-- Two single clicks slower than DOUBLE_CLICK_MS apart must NOT maximize —
-- just two ordinary drags. Uses a fresh window: b was already closed by
-- the close-button block above, so window_at(210, tby) would find
-- nothing and this block would test nothing.
do
  local c = wm:open { app = { draw = function() end }, x = 200, y = 100, w = 100, h = 100 }
  fake._set_now_ms(0)
  local tby = c.y + wm.border + 1
  aster.input.dispatch({ type = "mouse_down", x = 210, y = tby, button = "left" })
  aster.input.dispatch({ type = "mouse_up", button = "left" })
  fake._advance_ms(1000) -- past DOUBLE_CLICK_MS
  aster.input.dispatch({ type = "mouse_down", x = 210, y = tby, button = "left" })
  aster.input.dispatch({ type = "mouse_up", button = "left" })
  assert(c.x == 200 and c.y == 100 and c.w == 100 and c.h == 100,
    "two slow clicks on a title bar must not maximize")
end

print("mouse_input: PASS")
