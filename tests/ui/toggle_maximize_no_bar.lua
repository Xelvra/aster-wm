-- tests/ui/toggle_maximize_no_bar.lua — wm.bar == nil is a supported state
-- (adopt() sets it explicitly, M:render guards it, input.lua's drag clamp
-- guards it) but M:toggle_maximize did not: it dereferenced self.bar.height
-- unconditionally, so double-clicking a title bar with no bar configured
-- crashed the whole process. See spec/troubleshooting.md B44.

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
assert(wm.bar == nil, "this test only covers the no-bar configuration")

local win = wm:open { app = { draw = function() end }, x = 10, y = 10, w = 100, h = 100 }

fake._set_now_ms(0)
local tby = win.y + wm.border + 1
aster.input.dispatch({ type = "mouse_down", x = 50, y = tby, button = "left" })
aster.input.dispatch({ type = "mouse_up", button = "left" })
fake._advance_ms(100) -- well within DOUBLE_CLICK_MS
aster.input.dispatch({ type = "mouse_down", x = 50, y = tby, button = "left" })
aster.input.dispatch({ type = "mouse_up", button = "left" })

local out = aster.state.info.outputs[1]
local gout = wm.gaps.outer
assert(win.x == gout and win.y == gout, "maximize without a bar must start at the outer gap: got " .. win.x .. "," .. win.y)
assert(win.w == out.w - 2 * gout and win.h == out.h - 2 * gout,
  "maximize without a bar must fill the screen minus the outer gap: got " .. win.w .. "x" .. win.h)

print("toggle_maximize_no_bar: PASS")
