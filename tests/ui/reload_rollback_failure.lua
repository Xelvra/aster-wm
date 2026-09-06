-- tests/ui/reload_rollback_failure.lua — ADR-003's reload protocol, last safety net:
-- if even re-running the last known-good source fails, fall back to the
-- built-in default rather than a blank screen.
--
-- Constructed via a config that is only good the *first* time it runs (it
-- trips itself on a second execution) — legitimate on initial boot, but
-- fails when reload tries to replay it as a rollback after a later,
-- runtime-broken config triggers one.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
_G.__rollback_test_runs = 0
host.write("/cfg/wm.lua", [[
_G.__rollback_test_runs = _G.__rollback_test_runs + 1
if _G.__rollback_test_runs > 1 then error("only good once") end
local aster = require("aster")
return aster.wm.adopt {}
]])

aster.boot()
assert(aster.state.wm, "initial boot with the once-good config must succeed")

host.write("/cfg/wm.lua", [[
error("new config broken")
]])
aster.reload()

assert(aster.state.wm, "rollback failure must still leave a usable wm, never a blank screen")
local bubble = aster.state.error_bubble
assert(bubble and bubble.line1 == "config rollback failed, running built-in defaults",
  "the bubble must say the rollback itself failed: " .. tostring(bubble and bubble.line1))
assert(bubble.line2 == nil, "the rollback-failure bubble has no previous config left to name, so just one line")

-- The bubble's claim must be true, not just displayed: the singleton must
-- actually BE the built-in default (background/accent/super+q), not
-- whatever the once-good config happened to leave behind (it never set a
-- theme at all, so this only holds if builtin_default() really ran).
assert(aster.state.wm.theme.background == 0x1e2327,
  "rollback failure must actually apply the built-in theme, not just claim to")
assert(aster.state.wm.keybindings["super+q"] ~= nil,
  "rollback failure must actually rebind the built-in super+q, not just claim to")

print("reload_rollback_failure: PASS")
