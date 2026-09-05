-- spec/conformance/02_surface.lua — a write appears; clip is respected;
-- push_clip/pop_clip pair correctly. `get_pixel` is a __native_render-only
-- test hook (not part of the host contract, see src/host/bindings.zig).

local r = require("aster.render")
local s = host.surface()

r.fill_rect(s, 2, 2, 1, 1, 0x123456)
assert(r.get_pixel(s, 2, 2) == 0x123456, "a fill_rect write must be visible at that pixel")

r.fill_rect(s, 0, 0, 10, 10, 0x000000)
r.push_clip(s, 0, 0, 2, 2)
r.fill_rect(s, 0, 0, 10, 10, 0xabcdef)
r.pop_clip(s)
assert(r.get_pixel(s, 1, 1) == 0xabcdef, "inside the clip rect must be painted")
assert(r.get_pixel(s, 5, 5) == 0x000000, "outside the clip rect must be untouched")

-- push_clip/pop_clip must nest: popping restores the previous clip, not "no clip"
r.fill_rect(s, 0, 0, 10, 10, 0x000000)
r.push_clip(s, 0, 0, 4, 4)
r.push_clip(s, 0, 0, 1, 1)
r.pop_clip(s)
r.fill_rect(s, 0, 0, 10, 10, 0x111111)
assert(r.get_pixel(s, 2, 2) == 0x111111, "after one pop, the outer clip (4x4) should still apply")
assert(r.get_pixel(s, 5, 5) == 0x000000, "outside the restored outer clip must stay untouched")
r.pop_clip(s)

print("02_surface: PASS")
