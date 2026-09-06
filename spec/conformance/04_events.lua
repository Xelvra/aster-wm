-- spec/conformance/04_events.lua — the most important test in the suite
-- (spec/host-contract.md's "Events" section): wait(0) is nil only when the
-- queue is truly empty; key_down and text arrive as two SEPARATE events,
-- never one derived from the other; mods are consistent; focus loss is its
-- own event; a nonzero timeout actually blocks.
--
-- host._inject queues events directly, bypassing a real backend's own
-- translation layer (the sdl backend's mapScancode()/modsFrom() and mouse
-- coordinate handling) entirely — this suite does not and cannot exercise
-- that translation from this side. A backend claiming to pass this file is
-- claiming its event *shapes* and *ordering* are correct, not that its
-- real-input translation is bug-free; that still needs the manual
-- interactive check the SKIP message below points at.

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

-- host-contract.md's "Events" section: Lua holds no modifier state of its
-- own between events, so every key_down/key_up must carry the FULL,
-- independent modifier set for that exact keypress — never a merge with
-- whatever the previous event happened to hold. A backend that (bug)
-- carried modifier state forward would still pass the single-event checks
-- above; this specifically checks a shift-held event followed by one with
-- shift released.
host._inject({ type = "key_down", key = "a", mods = { ctrl = false, alt = false, shift = true, super = false } })
host._inject({ type = "key_down", key = "b", mods = { ctrl = false, alt = false, shift = false, super = false } })
evs = drain()
assert(#evs == 2 and evs[1].mods.shift == true, "first event must keep its own shift=true")
assert(evs[2].mods.shift == false, "second event's mods must not inherit shift from the previous event")

-- A nonzero timeout must actually block for roughly that long when the
-- queue is empty — host.wait(0) alone (used above and by aster.frame())
-- never exercises this, so nothing previously did.
assert(host.wait(0) == nil, "queue must be empty before the timeout check")
local before = host.now_ms()
local timed_out = host.wait(50)
local elapsed = host.now_ms() - before
assert(timed_out == nil, "an empty queue must still return nil after the timeout elapses")
assert(elapsed >= 25, "host.wait(50) returned almost immediately (" .. elapsed .. "ms) — it must actually block")

print("04_events: PASS")
