-- tests/ui/reload_mtime_watch.lua — ADR-003/architecture.md "Reload preserves
-- state": an external editor
-- saving wm.lua must be picked up within one poll, including an edit made
-- before this process ever got to run its first poll (loop.lua primes the
-- mtime baseline at boot, from aster.boot(), precisely so that edit isn't
-- silently absorbed as the new baseline instead of triggering a reload).

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x111111 }
return wm
]])

aster.boot()
fake._set_now_ms(0)
aster.frame() -- a poll with nothing changed must not reload

-- Edited before the watch has ever had a chance to observe a baseline
-- other than the one boot() itself primed.
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x222222 }
return wm
]])
fake._set_now_ms(1500) -- past loop.lua's 1000ms poll interval
aster.frame()

assert(aster.state.wm.theme.accent == 0x222222,
  "an edit made before the first poll must still be picked up by that first poll")

-- Steady state: a second edit, a second poll, must also work.
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x333333 }
return wm
]])
fake._set_now_ms(3000)
aster.frame()
assert(aster.state.wm.theme.accent == 0x333333, "a later edit must also be picked up")

-- No spurious reload when nothing changed between polls.
local before = aster.state.wm
fake._set_now_ms(4500)
aster.frame()
assert(aster.state.wm == before, "a poll with no file change must not touch the wm singleton")

print("reload_mtime_watch: PASS")
