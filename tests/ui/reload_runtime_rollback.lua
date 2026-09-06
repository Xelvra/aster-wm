-- tests/ui/reload_runtime_rollback.lua — ADR-003 §6.4 step 4: a config
-- that compiles but throws (or fails verification by not returning the
-- adopted wm) must roll back to the last known-good source, not just
-- leave the singleton half-configured.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0xaaaaaa }
wm:bind("super+x", function() end)
return wm
]])

aster.boot()
local wm1 = aster.state.wm

-- Throws at runtime, after mutating the singleton via adopt() (which
-- would otherwise leave keybindings reset and theme empty).
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
error("boom mid-config")
]])
aster.reload()

assert(aster.state.wm == wm1, "rollback must not replace the wm singleton")
assert(aster.state.wm.theme.accent == 0xaaaaaa, "rollback must re-apply the last known-good config")
assert(next(aster.state.wm.keybindings) ~= nil, "rollback must re-apply keybindings the failed config had reset")
local bubble = aster.state.error_bubble
assert(bubble and bubble.line1:find("boom mid%-config"), "the bubble must name the runtime error")
assert(bubble.line2 == "keeping previous config — desktop untouched")

-- A config that never returns the adopted instance fails verification
-- (step 5) the same way — even though adopt() already ran.
host.write("/cfg/wm.lua", [[
local aster = require("aster")
aster.wm.adopt {}
return {} -- forgot to return the adopted wm
]])
aster.reload()

assert(aster.state.wm == wm1, "a verify failure must not replace the wm singleton")
assert(aster.state.wm.theme.accent == 0xaaaaaa, "a verify failure must roll back to the last known-good config")
assert(aster.state.error_bubble ~= nil, "a verify failure must show the error bubble")

print("reload_runtime_rollback: PASS")
