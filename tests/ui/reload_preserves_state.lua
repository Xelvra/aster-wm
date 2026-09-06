-- tests/ui/reload_preserves_state.lua — ADR-003: state survives, code is
-- replaced. Only the happy path (a config that recompiles cleanly) is
-- covered here; rollback, verify-failure and the error bubble have their
-- own suites (reload_runtime_rollback.lua, reload_rollback_failure.lua,
-- reload_error_bubble.lua).

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0xff0000 }
return wm
]])

aster.boot()
local wm1 = aster.state.wm
local win = wm1:open { app = { draw = function() end } }
local id = win.id

aster.reload()

assert(aster.state.wm == wm1, "adopt() must return the same wm instance across a reload")
assert(aster.state.windows[id] == win, "reloading must not close or replace existing windows")
assert(aster.state.wm.theme.accent == 0xff0000, "the reloaded config's overrides must take effect")

print("reload_preserves_state: PASS")
