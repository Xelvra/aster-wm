-- tests/ui/crash_isolation.lua — spec/architecture.md's "Windows and apps": an app that
-- throws from draw() or tick() closes only its own window, is logged, and
-- never takes the rest of the desktop down.

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

local good = { draw = function() end, tick = function() return false end }
local bad_draw = { draw = function() error("boom in draw") end }
local bad_tick = { draw = function() end, tick = function() error("boom in tick") end }

local w_good = wm:open { app = good }
local w_bad_draw = wm:open { app = bad_draw }
local w_bad_tick = wm:open { app = bad_tick }

wm:render(host.surface())
assert(aster.state.windows[w_bad_draw.id] == nil, "a crashing draw() must close only its own window")
assert(aster.state.windows[w_good.id] ~= nil, "sibling windows must survive a crash in draw()")
assert(aster.state.windows[w_bad_tick.id] ~= nil, "draw() crashing must not touch an unrelated window")
assert(#fake.log_lines > 0, "a crash must be logged, never swallowed silently")

wm:tick(1000)
assert(aster.state.windows[w_bad_tick.id] == nil, "a crashing tick() must close only its own window")
assert(aster.state.windows[w_good.id] ~= nil, "sibling windows must survive a crash in tick()")

print("crash_isolation: PASS")
