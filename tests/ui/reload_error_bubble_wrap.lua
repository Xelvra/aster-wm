-- tests/ui/reload_error_bubble_wrap.lua — B11: a long error message must
-- wrap and cap, never overrun the screen. Verified by capturing the actual
-- __native_render calls wm:render() makes, not just that it doesn't crash
-- (fakehost's render stubs only validate argument shapes, so a bubble
-- drawn far off-screen would otherwise pass silently).

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
return aster.wm.adopt {}
]])
aster.boot()

-- One 300-character token with no spaces: nothing to greedily wrap on, so
-- this only comes out short if the hard-split-by-character path works.
host.write("/cfg/wm.lua", "error('" .. string.rep("x", 300) .. "')")
aster.reload()
assert(aster.state.error_bubble, "the broken config must still produce a bubble")

-- wm.lua draws through require("aster.render"), a cached module table —
-- patch ITS fields (not __native_render's) so the substitution is visible
-- through the same table reference wm.lua already holds.
local render_mod = require("aster.render")
local texts, rects = {}, {}
local orig_text, orig_fill = render_mod.text, render_mod.fill_rect
render_mod.text = function(s, x, y, str, color)
  texts[#texts + 1] = str
  return orig_text(s, x, y, str, color)
end
render_mod.fill_rect = function(s, x, y, w, h, color)
  rects[#rects + 1] = { x = x, y = y, w = w, h = h }
  return orig_fill(s, x, y, w, h, color)
end

aster.state.wm:render(host.surface())

render_mod.text = orig_text
render_mod.fill_rect = orig_fill

assert(#texts > 1, "a 300-character message with no spaces must be wrapped across multiple lines")
for _, t in ipairs(texts) do
  assert(#t * 8 <= 480, "no single drawn line may be wider than the bubble's max width, got " .. #t .. " chars")
end
assert(#texts <= 6, "the bubble must cap the number of lines it draws, got " .. #texts)

-- rects[1] is the desktop background (no windows are open in this test),
-- so rects[#rects] is the bubble's own background box.
local bubble = rects[#rects]
assert(bubble.x >= 0, "the bubble must stay fully on-screen, got x=" .. bubble.x)
assert(bubble.x + bubble.w <= aster.info.outputs[1].w,
  "the bubble must not extend past the right edge either")

print("reload_error_bubble_wrap: PASS")
