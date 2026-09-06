-- tests/ui/keybindings.lua — a keybinding must still fire when an event's
-- mods table omits a key that's simply not held (never nil-vs-false), and
-- a typo'd modifier name must be rejected loudly at bind time rather than
-- silently registering as a weaker binding.

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

local fired = false
wm:bind("super+q", function() fired = true end)

-- A sparse mods table (as a hand-built event, not one from _push_key,
-- would arrive) must still match: a missing key means "not held", not
-- "binding disabled".
aster.input.dispatch({ type = "key_down", key = "q", mods = { super = true } })
assert(fired, "a keybinding must fire even when the event's mods table omits false modifiers")

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local before = count(wm.keybindings)
local logged_before = #fake.log_lines
local shft_w_fired = false
wm:bind("shft+w", function() shft_w_fired = true end)
assert(count(wm.keybindings) == before, "a keybinding with an unknown modifier must not be registered")
assert(#fake.log_lines > logged_before, "an unknown modifier must be logged, not silently accepted")

-- Confirms the typo'd bind didn't quietly register as the equivalent of a
-- bare "w" binding (the exact failure mode this test guards against): a
-- plain, unmodified 'w' press must not trigger it.
aster.input.dispatch({ type = "key_down", key = "w", mods = { ctrl = false, alt = false, shift = false, super = false } })
assert(not shft_w_fired, "'shft+w' must not behave like a plain 'w' binding")

print("keybindings: PASS")
