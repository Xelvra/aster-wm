-- spec/conformance/01_info.lua — host.info() shape, per spec/host-contract.md.

local info = host.info()

assert(type(info.backend) == "string" and #info.backend > 0, "backend must be a non-empty string")
assert(info.format == "xrgb8888", "v1 supports exactly one format, got " .. tostring(info.format))

assert(type(info.outputs) == "table" and #info.outputs > 0, "outputs must be a non-empty array")
local out = info.outputs[1]
assert(type(out.w) == "number" and out.w > 0, "outputs[1].w must be a positive number")
assert(type(out.h) == "number" and out.h > 0, "outputs[1].h must be a positive number")
assert(info.pitch >= out.w * 4, "pitch must be at least w*4 for xrgb8888")

for _, key in ipairs({ "config", "data", "home" }) do
  local p = info.paths[key]
  assert(type(p) == "string", "paths." .. key .. " must be a string")
  assert(p:sub(1, 1) == "/", "paths." .. key .. " must be absolute, got " .. tostring(p))
  assert(not p:find("~"), "paths." .. key .. " must not contain ~")
end

for _, key in ipairs({ "clock", "spawn", "damage", "inject" }) do
  assert(type(info.caps[key]) == "boolean", "caps." .. key .. " must always be present as a boolean")
end

print("01_info: PASS")
