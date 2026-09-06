-- tests/ui/draw_frame_crash.lua — a crash in a config's draw_frame (the
-- one function README/demos tell users to redefine live) must never take
-- the desktop down, and must never close the window either: the bug is in
-- the config, not the app running inside that window.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
function wm:draw_frame(win) return self.theme.missing.field end
return wm
]])

aster.boot()
local wm = aster.state.wm
local win = wm:open { app = { draw = function() end } }

wm:render(host.surface())

assert(aster.state.windows[win.id] ~= nil, "a crashing draw_frame must not close the window it was framing")
assert(#fake.log_lines > 0, "a crashing draw_frame must be logged, never swallowed silently")

-- Must have self-healed by falling back to the built-in frame, so a
-- second frame (and every frame after) renders clean instead of
-- re-crashing (and re-logging) once per window per frame forever.
local lines_after_first_render = #fake.log_lines
wm:render(host.surface())
assert(#fake.log_lines == lines_after_first_render, "the fallback must stick — no repeat crash on the next frame")

print("draw_frame_crash: PASS")
