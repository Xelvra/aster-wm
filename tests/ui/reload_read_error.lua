-- tests/ui/reload_read_error.lua — B14: host.read(wm.lua) failing with
-- anything other than "not_found" (permission, io, busy, invalid — the file
-- exists but can't be read) must never crash the process, on first boot or
-- on a later reload, and must surface an error bubble like every other
-- reload failure.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })

-- First boot: the config "exists" but can't be read at all. Before B14's
-- fix, aster.state.wm stayed nil here and the next render() call crashed
-- the whole process (loop.lua's tick() is guarded, render() wasn't).
fake._set_read_error("/cfg/wm.lua", "permission")
aster.boot()

assert(aster.state.wm ~= nil, "a read error on first boot must still produce a working wm (built-in default)")
local bubble = aster.state.error_bubble
assert(bubble, "a read error on first boot must show an error bubble")
assert(bubble.line1:find("permission"), "the bubble must name the error: " .. tostring(bubble.line1))

-- The desktop must actually be usable, not just non-nil: render() must not
-- throw, and windows opened against the fallback wm must work normally.
aster.state.wm:render(host.surface())
local win = aster.state.wm:open { app = { draw = function() end } }
assert(aster.state.windows[win.id] ~= nil, "the fallback wm from a read error must be fully functional")

-- Recovering: a working config, once readable, replaces the fallback and
-- clears the bubble, same as any other reload failure recovers.
fake._set_read_error("/cfg/wm.lua", nil)
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x00ff00 }
return wm
]])
aster.reload()
assert(aster.state.error_bubble == nil, "a successful reload after a read error must clear the bubble")
assert(aster.state.wm.theme.accent == 0x00ff00, "the recovered config must take effect")

-- A read error on a LATER reload (wm already running) must keep the
-- previous config running, not fall back to built-in defaults.
fake._set_read_error("/cfg/wm.lua", "io")
aster.reload()
assert(aster.state.wm.theme.accent == 0x00ff00, "a later read error must keep the previous config running")
bubble = aster.state.error_bubble
assert(bubble, "a later read error must show an error bubble")
assert(bubble.line2 == "keeping previous config — desktop untouched", "the bubble's second line is fixed wording")

print("reload_read_error: PASS")
