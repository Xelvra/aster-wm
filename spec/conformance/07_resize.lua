-- spec/conformance/07_resize.lua — a resize event means surface() and
-- info() both already reflect the new dimensions.

if not host.info().caps.inject then
  error("SKIP: caps.inject=false — run interactively: resize the window", 0)
end

local info1 = host.info()
local out1 = info1.outputs[1]
local new_w, new_h = out1.w + 37, out1.h + 41 -- odd deltas so a coincidence is implausible

host._inject({ type = "resize", w = new_w, h = new_h })

local got_resize = false
for _ = 1, 20 do
  local e = host.wait(0)
  if not e then break end
  if e.type == "resize" then
    assert(e.w == new_w and e.h == new_h, "resize event dimensions must match what was injected")
    got_resize = true
  end
end
assert(got_resize, "expected a resize event after host._inject")

assert(host.surface() ~= nil, "surface() must return a valid surface after resize")
local out2 = host.info().outputs[1]
assert(out2.w == new_w and out2.h == new_h, "info() must report the new dimensions after resize")

print("07_resize: PASS")
