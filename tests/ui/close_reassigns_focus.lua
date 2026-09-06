-- tests/ui/close_reassigns_focus.lua — closing the focused window must not
-- leave the keyboard dead while other windows are still open: focus moves
-- to whatever's now on top.

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

local a_keys, b_keys, c_keys = {}, {}, {}
local a = wm:open { app = { draw = function() end, key = function(_, key) a_keys[#a_keys + 1] = key end } }
local b = wm:open { app = { draw = function() end, key = function(_, key) b_keys[#b_keys + 1] = key end } }
local c = wm:open { app = { draw = function() end, key = function(_, key) c_keys[#c_keys + 1] = key end } }

wm:focus_window(b) -- raise+focus b, so closing it must fall back to c (next-highest z), not a

wm:close(b)
assert(aster.state.focus == c.id, "closing the focused window must hand focus to the next-highest-z window")

fake._push_key("j", { ctrl = false, alt = false, shift = false, super = false })
aster.frame()
assert(#c_keys == 1 and c_keys[1] == "j", "keyboard input must reach the new focus after a close")
assert(#a_keys == 0, "keyboard input must not reach a window that wasn't given focus")

wm:close(a)
wm:close(c)
assert(aster.state.focus == nil, "closing every window must leave focus nil, not dangling")

print("close_reassigns_focus: PASS")
