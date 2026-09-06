-- tests/ui/frame_lifecycle.lua — ADR-002/spec/host-contract.md: aster.frame()
-- returns exactly one of "running" / "idle" / "quit", and that trio is the
-- whole basis for the host blocking between frames instead of spinning
-- (see B6 in spec/troubleshooting.md). Nothing exercised this return value
-- directly before — B18's resize/dirty bug would have been caught by this
-- test on its own.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
return aster.wm.adopt {}
]])
aster.boot()

assert(aster.frame() == "running", "the first frame after boot must run (boot marks the frame dirty)")
assert(aster.frame() == "idle", "a frame with nothing changed must report idle, not running")

-- B18: a resize event must mark the frame dirty, since the backend hands
-- over a freshly allocated, blank surface that needs a repaint.
fake._push_resize(800, 600)
assert(aster.frame() == "running", "a resize event must cause the next frame to run, not stay idle")
assert(aster.frame() == "idle", "the frame after a handled resize must go back to idle")

-- An explicit mark_dirty() must also produce a "running" frame.
aster.mark_dirty()
assert(aster.frame() == "running", "mark_dirty() must cause the next frame to run")
assert(aster.frame() == "idle", "idle must hold again once nothing is left dirty")

fake._push_quit()
assert(aster.frame() == "quit", "a quit event must make frame() return \"quit\"")

print("frame_lifecycle: PASS")
