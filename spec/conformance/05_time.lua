-- spec/conformance/05_time.lua — now_ms is monotonic; clock() is either a
-- valid wall-clock reading or "unsupported", and that must agree with caps.

local t1 = host.now_ms()
for _ = 1, 1e6 do end -- burn a little wall time so t2 can plausibly differ
local t2 = host.now_ms()
assert(type(t1) == "number" and type(t2) == "number", "now_ms must return a number")
assert(t2 >= t1, "now_ms must never go backwards")

local info = host.info()
local clock, err = host.clock()
if info.caps.clock then
  assert(clock ~= nil, "clock() must succeed when caps.clock is true")
  assert(type(clock.unix_ms) == "number", "clock().unix_ms must be a number")
  assert(type(clock.utc_offset_min) == "number", "clock().utc_offset_min must be a number")
  -- A real UTC offset is always within [-12h, +14h] in minutes; a
  -- placeholder value hardcoded to 0 would pass a bare type check but is
  -- wrong everywhere except UTC itself, so check the range explicitly.
  -- This does not, by itself, prove the offset matches the machine's
  -- actual zone — cross-check `date +%z` by hand when touching this.
  assert(clock.utc_offset_min >= -720 and clock.utc_offset_min <= 840,
    "clock().utc_offset_min must be a plausible UTC offset in minutes, got " .. tostring(clock.utc_offset_min))
else
  assert(clock == nil and err == "unsupported", "clock() must be nil, 'unsupported' when caps.clock is false")
end

print("05_time: PASS")
