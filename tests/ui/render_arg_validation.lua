-- tests/ui/render_arg_validation.lua — B17: an app passing a bad argument
-- to a __native_render function (a coordinate/size out of range, a missing
-- or wrong-typed surface) must raise a normal Lua error that wm:guard
-- catches and turns into a closed window — exactly like any other app
-- crash (see tests/ui/crash_isolation.lua) — never a Zig panic that takes
-- the whole process down. fakehost.lua's checks are meant to mirror
-- src/host/bindings.zig's checkI32/checkU32/surfaceArg exactly, so this
-- test exercises the same argument shapes that would panic the real
-- renderer.

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

local good = { draw = function() end }
local negative_width = {
  draw = function(win, surface) aster.render.fill_rect(surface, win.x, win.y, -1, win.h, 0x00ff00) end,
}
local missing_surface = {
  -- forgot the `surface` parameter: passes `win` (a table, but not a
  -- surface) where the renderer expects the drawing target.
  draw = function(win) aster.render.fill_rect(win, win.x, win.y, win.w, win.h, 0x00ff00) end,
}
local huge_color = {
  draw = function(win, surface) aster.render.fill_rect(surface, win.x, win.y, win.w, win.h, 2 ^ 40) end,
}

local w_good = wm:open { app = good }
local w_negative = wm:open { app = negative_width }
local w_missing = wm:open { app = missing_surface }
local w_huge = wm:open { app = huge_color }

wm:render(host.surface())

assert(aster.state.windows[w_negative.id] == nil, "a negative width must close only the offending window, not crash")
assert(aster.state.windows[w_missing.id] == nil, "a missing/wrong-typed surface must close only the offending window")
assert(aster.state.windows[w_huge.id] == nil, "a color value outside u32 range must close only the offending window")
assert(aster.state.windows[w_good.id] ~= nil, "sibling windows must survive a neighbor's bad render argument")
assert(#fake.log_lines > 0, "a bad render argument must be logged, never swallowed silently")

print("render_arg_validation: PASS")
