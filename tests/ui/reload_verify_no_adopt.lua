-- tests/ui/reload_verify_no_adopt.lua — B16: a config that compiles and
-- runs clean but never calls aster.wm.adopt() must fail reload's verify
-- step even on the very first boot, where aster.state.wm starts out nil
-- and `result ~= M.state.wm` alone (nil ~= nil == false) would otherwise
-- let it through.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })

-- The simplest config that "compiles and runs without error but never
-- adopts": an empty file. It has to fail exactly like a runtime error, not
-- silently pass verification and leave aster.state.wm nil.
host.write("/cfg/wm.lua", "")
aster.boot()

assert(aster.state.wm ~= nil, "a non-adopting config on first boot must still produce a working wm (built-in default)")
-- There is no previous good source to roll back to on a first boot, so
-- this hits the same "config rollback failed" branch B10 fixed — the
-- bubble's wording is generic, but state.wm being a working fallback is
-- what matters here.
local bubble = aster.state.error_bubble
assert(bubble, "a non-adopting config on first boot must show an error bubble")

-- Before B16's fix this line indexed a nil aster.state.wm and crashed the
-- whole process (loop.lua's tick() was guarded, render() wasn't).
aster.mark_dirty()
local status = aster.frame()
assert(status == "running", "frame() must run to completion with the built-in default in place, got " .. tostring(status))

-- A config that returns a value, but not the one it just adopted, must
-- fail the same way (covers the general case, not just "returns nothing").
host.write("/cfg/wm.lua", [[
local aster = require("aster")
aster.wm.adopt {}
return "not the wm"
]])
aster.reload()
assert(aster.state.error_bubble ~= nil, "returning a non-wm value must also fail verification")

print("reload_verify_no_adopt: PASS")
