-- tests/ui/workspaces.lua — lua/aster/wm.lua's workspace support: every
-- window belongs to one (win.ws, defaulting to whatever was current when
-- it opened), and wm:goto_workspace/window_at/close only ever see the
-- current workspace's windows — a click, a close-reassigned focus, or a
-- keyboard event must never land on a window the user can't currently see.

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

assert(aster.state.current_ws == 1, "boot must start on workspace 1")

local a = wm:open { app = { draw = function() end }, x = 0, y = 0, w = 100, h = 100 }
assert(a.ws == 1, "a window opens onto whatever workspace is current")

wm:goto_workspace(2)
assert(aster.state.current_ws == 2, "goto_workspace must switch the current workspace")
assert(aster.state.focus == nil, "switching to an empty workspace must clear focus, not point at a's window")

local b = wm:open { app = { draw = function() end }, x = 0, y = 0, w = 100, h = 100 }
assert(b.ws == 2, "a window opened after switching lands on the new current workspace")
assert(aster.state.focus == b.id, "opening a window still focuses it")

-- window_at only ever sees the current workspace.
assert(wm:window_at(50, 50) == b, "window_at must find a window on the current workspace")
wm:goto_workspace(1)
assert(wm:window_at(50, 50) == a, "window_at must find workspace 1's window after switching back")
assert(aster.state.focus == a.id, "switching to a workspace with a window must refocus to it")

-- move_to_workspace reassigns ws and the window promptly becomes
-- unreachable by window_at on the workspace it left.
wm:move_to_workspace(a, 2)
assert(a.ws == 2, "move_to_workspace must reassign win.ws")
assert(wm:window_at(50, 50) == nil, "a window just moved off this workspace must not be findable here anymore")
wm:goto_workspace(2)
assert(wm:window_at(50, 50) == a or wm:window_at(50, 50) == b, "workspace 2 now has both windows stacked at the same spot")

-- close() only reassigns focus within the current workspace, never to a
-- window hidden on another one.
wm:goto_workspace(1)
assert(wm:window_at(50, 50) == nil, "workspace 1 is now empty (a moved away)")
local c = wm:open { app = { draw = function() end }, x = 0, y = 0, w = 50, h = 50 }
wm:close(c)
assert(aster.state.focus == nil, "closing the last window on this workspace must not refocus a hidden window on another one")

print("workspaces: PASS")
