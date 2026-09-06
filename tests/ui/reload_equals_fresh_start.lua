-- tests/ui/reload_equals_fresh_start.lua — ADR-003 Consequences: "tests/ui/
-- must assert that reloading a file produces a state identical to starting
-- fresh with that file, windows aside." Existing tests each cover one
-- consequence of that (theme resets, keybindings reset, the singleton
-- stays the same instance) but nothing asserted the claim as a whole
-- before this test: that reloading config A, after some other config ran
-- in between, leaves the wm exactly as if aster had booted fresh with A —
-- while windows opened along the way are the one thing that must NOT
-- match a fresh start (they must survive, untouched).

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

local CONFIG_A = [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0xaabbcc, background = 0x111111 }
wm:bind("super+x", function() end)
wm:bind("super+y", function() end)
return wm
]]

local CONFIG_B = [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x998877 }
wm:bind("super+z", function() end)
function wm:draw_frame(win, surface) end
return wm
]]

local function keybinding_names(wm)
  local names = {}
  for spec in pairs(wm.keybindings) do names[#names + 1] = spec end
  table.sort(names)
  return names
end

local function snapshot(wm)
  local wm_mod = require("aster.wm")
  return {
    theme_accent = wm.theme.accent,
    theme_background = wm.theme.background,
    keybindings = keybinding_names(wm),
    draw_frame_is_default = wm.draw_frame == wm_mod.default_draw_frame,
  }
end

local function assert_equal_snapshots(fresh, reloaded)
  assert(fresh.theme_accent == reloaded.theme_accent, "theme.accent must match a fresh start")
  assert(fresh.theme_background == reloaded.theme_background, "theme.background must match a fresh start")
  assert(fresh.draw_frame_is_default == reloaded.draw_frame_is_default, "draw_frame override state must match a fresh start")
  assert(#fresh.keybindings == #reloaded.keybindings, "keybinding count must match a fresh start")
  for i, name in ipairs(fresh.keybindings) do
    assert(reloaded.keybindings[i] == name, "keybinding set must match a fresh start exactly, got " .. table.concat(reloaded.keybindings, ",") .. " vs " .. table.concat(fresh.keybindings, ","))
  end
end

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })

-- A genuine fresh start with config A.
host.write("/cfg/wm.lua", CONFIG_A)
aster.boot()
local fresh_snapshot = snapshot(aster.state.wm)

-- Open a window: this is the one thing that must survive the reloads
-- below untouched, unlike everything captured in the snapshot.
local win = aster.state.wm:open { app = { draw = function() end } }
local win_id = win.id

-- Some other config runs in between...
host.write("/cfg/wm.lua", CONFIG_B)
aster.reload()
assert(aster.state.wm.theme.accent == 0x998877, "config B must have taken effect")

-- ...then config A comes back. The result must be identical to the fresh
-- start above, windows aside.
host.write("/cfg/wm.lua", CONFIG_A)
aster.reload()
local reloaded_snapshot = snapshot(aster.state.wm)

assert_equal_snapshots(fresh_snapshot, reloaded_snapshot)
assert(aster.state.windows[win_id] ~= nil, "the window opened before these reloads must still be open")
assert(aster.state.windows[win_id] == win, "the window must be the exact same object, not a recreated one")

print("reload_equals_fresh_start: PASS")
