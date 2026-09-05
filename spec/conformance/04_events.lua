-- spec/conformance/04_events.lua — the most important test in the suite
-- (spec §9.4): wait(0) is nil only when the queue is truly empty; key_down
-- and text arrive as two SEPARATE events, never one derived from the
-- other; mods are consistent; focus loss is its own event.

if not host.info().caps.inject then
  error("SKIP: caps.inject=false — run interactively: press A, then Shift+A, then Escape, then Alt-Tab away", 0)
end

local function drain()
  local out = {}
  while true do
    local e = host.wait(0)
    if not e then break end
    out[#out + 1] = e
  end
  return out
end

drain() -- flush startup noise (e.g. an initial focus event)
assert(host.wait(0) == nil, "wait(0) must return nil on an empty queue")

host._inject({ type = "key_down", key = "a", mods = { ctrl = false, alt = false, shift = false, super = false } })
host._inject({ type = "text", text = "a" })
local evs = drain()
assert(#evs == 2, "key_down + text must arrive as two events, got " .. #evs)
assert(evs[1].type == "key_down" and evs[1].key == "a", "first event must be key_down 'a'")
assert(type(evs[1].mods) == "table", "key_down must carry a mods table")
assert(evs[1].mods.ctrl == false and evs[1].mods.shift == false, "mods must reflect what was injected")
assert(evs[2].type == "text" and evs[2].text == "a", "second event must be a separate text event")

host._inject({ type = "key_down", key = "a", mods = { ctrl = false, alt = false, shift = true, super = false } })
evs = drain()
assert(#evs == 1 and evs[1].mods.shift == true, "Shift must show up in mods, not change which key name is sent")

host._inject({ type = "focus", focused = false })
evs = drain()
assert(#evs == 1 and evs[1].type == "focus" and evs[1].focused == false, "focus loss must arrive as its own event")

print("04_events: PASS")
