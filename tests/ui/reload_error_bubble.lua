-- tests/ui/reload_error_bubble.lua — ADR-003 §6.6: a failed reload shows a
-- bubble drawn from Lua, dismissed by the next successful reload or by
-- Escape. Covers the syntax-error path and the two ways to clear it.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x00ff00 }
return wm
]])

aster.boot()
assert(aster.state.error_bubble == nil, "a clean boot must show no error bubble")

-- A syntax error must keep the running config and show a bubble naming
-- the bad line, per spec/architecture.md "Reload preserves state".
host.write("/cfg/wm.lua", "this is not lua (")
aster.reload()

assert(aster.state.wm.theme.accent == 0x00ff00, "a syntax error must keep the previous config running")
local bubble = aster.state.error_bubble
assert(bubble, "a syntax error must show an error bubble")
assert(bubble.line1:find("wm%.lua"), "the bubble must name the file/line: " .. tostring(bubble.line1))
assert(bubble.line2 == "keeping previous config — desktop untouched", "the bubble's second line is fixed wording")

-- Escape dismisses it without touching the running config.
aster.input.dispatch({ type = "key_down", key = "escape", mods = { ctrl = false, alt = false, shift = false, super = false } })
assert(aster.state.error_bubble == nil, "Escape must dismiss the error bubble")
assert(aster.state.wm.theme.accent == 0x00ff00, "dismissing the bubble must not touch the running config")

-- Escape with no bubble showing is a no-op, not an error.
aster.input.dispatch({ type = "key_down", key = "escape", mods = { ctrl = false, alt = false, shift = false, super = false } })

-- A second, valid reload also clears any bubble that's showing.
host.write("/cfg/wm.lua", "this is not lua (")
aster.reload()
assert(aster.state.error_bubble ~= nil, "re-arm: a second syntax error should show the bubble again")

host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x0000ff }
return wm
]])
aster.reload()
assert(aster.state.error_bubble == nil, "a successful reload must clear the error bubble")
assert(aster.state.wm.theme.accent == 0x0000ff, "the successful reload's config must take effect")

print("reload_error_bubble: PASS")
