-- tests/ui/render_bind_and_alpha.lua — r.bind(s) (lua/aster/render.lua)
-- and fill_rect/round_rect's optional alpha argument.
-- fakehost.lua only validates argument shape (drawing itself is a no-op),
-- so this checks that r.bind forwards the surface and the real arguments
-- correctly, and that alpha is accepted in range and rejected out of it —
-- the actual pixel-level behavior is spec/conformance/02_surface.lua's job
-- against the real renderer.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local r = require("aster.render")

local s = host.surface()
local other = host.surface()

-- r.bind reads M.raw at bind() time (each call builds a fresh closure
-- table), so the spy has to replace r.raw.fill_rect — the field bind()
-- actually captures — not __native_render.fill_rect, which r.bind never
-- looks at again once render.lua has cached it into r.raw at module load.
local seen
local calls = 0
local orig_fill_rect = r.raw.fill_rect
r.raw.fill_rect = function(surface, x, y, w, h, color, alpha)
  calls = calls + 1
  seen = { surface = surface, x = x, y = y, w = w, h = h, color = color, alpha = alpha }
  return orig_fill_rect(surface, x, y, w, h, color, alpha)
end

local g = r.bind(s)
g.fill_rect(1, 2, 3, 4, 0x00ff00)
assert(calls == 1, "bound fill_rect must call through exactly once")
assert(seen.surface == s, "r.bind must forward the surface it was bound to, not some other one")
assert(seen.x == 1 and seen.y == 2 and seen.w == 3 and seen.h == 4 and seen.color == 0x00ff00,
  "r.bind must forward the caller's own arguments unchanged")
assert(seen.alpha == nil, "omitting alpha through a bound call must still omit it, not default it early")

local g2 = r.bind(other)
g2.fill_rect(0, 0, 1, 1, 0x000000)
assert(seen.surface == other, "a second r.bind(other) must close over `other`, not leak the first surface")

r.raw.fill_rect = orig_fill_rect

-- alpha argument shape: in range is fine, out of range must error the
-- same way a bad color/coordinate already does (B17).
local ok_in_range = pcall(r.fill_rect, s, 0, 0, 1, 1, 0xff0000, 128)
assert(ok_in_range, "alpha within 0-255 must be accepted")
local ok_out_of_range = pcall(r.fill_rect, s, 0, 0, 1, 1, 0xff0000, 256)
assert(not ok_out_of_range, "alpha above 255 must be rejected, not silently clamped")
local ok_round_rect = pcall(r.round_rect, s, 0, 0, 4, 4, 1, 0xff0000, 200)
assert(ok_round_rect, "round_rect must accept the same optional trailing alpha as fill_rect")

assert(#fake.log_lines == 0, "none of the above should have logged anything")

print("render_bind_and_alpha: PASS")
