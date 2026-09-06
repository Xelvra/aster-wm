-- tests/ui/window_stacking.lua — raising a window (input.lua's
-- mouse_down handler, via wm:focus_window) must change paint order, not
-- just the `z` field: input decides who's "on top" using the same `z`
-- render() uses to decide what to draw last.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
return aster.wm.adopt {}
]])

aster.boot()
local wm = aster.state.wm

local paint_order = {}
local function make_app(name)
  return { draw = function() paint_order[#paint_order + 1] = name end }
end

-- Three windows at the same spot, so window_at(50, 50) only ever has `z`
-- to break the tie.
local a = wm:open { app = make_app("a"), x = 0, y = 0, w = 100, h = 100 }
local b = wm:open { app = make_app("b"), x = 0, y = 0, w = 100, h = 100 }
local c = wm:open { app = make_app("c"), x = 0, y = 0, w = 100, h = 100 }

paint_order = {}
wm:render(host.surface())
assert(paint_order[#paint_order] == "c", "highest-z window (opened last) must paint last (on top)")
assert(wm:window_at(50, 50) == c, "window_at must agree with paint order")

wm:focus_window(a)
paint_order = {}
wm:render(host.surface())
assert(paint_order[#paint_order] == "a", "raising a must make it paint last, matching its new highest z")
assert(wm:window_at(50, 50) == a, "window_at must report the just-raised window as topmost")

print("window_stacking: PASS")
