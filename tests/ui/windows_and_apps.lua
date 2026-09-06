-- tests/ui/windows_and_apps.lua — ADR-007: windows have ids, apps are
-- dispatched by table reference, not looked up by name, and titles are not
-- unique.

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

local app_a = { draw = function() end }
local app_b = { draw = function() end }

local win_a = wm:open { app = app_a, title = "same-title" }
local win_b = wm:open { app = app_b, title = "same-title" }

assert(win_a.id ~= win_b.id, "two windows must get distinct ids")
assert(win_a.title == win_b.title, "title must not be required to be unique")
assert(aster.state.windows[win_a.id].app == app_a,
  "the core must dispatch to the exact app table given to wm:open, never by name")
assert(aster.state.windows[win_b.id].app == app_b,
  "the core must dispatch to the exact app table given to wm:open, never by name")

wm:close(win_a)
assert(aster.state.windows[win_a.id] == nil, "closing a window removes it from state.windows")
assert(aster.state.windows[win_b.id] ~= nil, "closing one window must not affect another")
assert(aster.state.focus ~= win_a.id, "closing the focused window must clear focus")

print("windows_and_apps: PASS")
