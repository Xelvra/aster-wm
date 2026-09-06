-- lua/aster/input.lua — events to actions. The launcher and key-repeat land
-- with bar.lua/launcher.lua in a later pass; this milestone routes key_down
-- through the keybinding table, then to the focused window, text to the
-- focused window only (spec/host-contract.md keeps key and text as two
-- separate events on purpose), and mouse to window focus/raise/drag.
-- There is no per-app mouse callback yet — apps only get draw/key/text/tick
-- (spec/architecture.md "Windows and apps") — so a click that isn't on a
-- window's border frame just focuses it.

local M = {}
local aster = require("aster")

-- Set while dragging a window by its border; not part of aster.state since
-- it's transient input state, not something a config reload should see.
local dragging = nil

-- The only modifier names a keybinding spec may use (spec/keys.md is
-- normative for key names; this is the equivalent list for modifiers).
local KNOWN_MODS = { ctrl = true, alt = true, shift = true, super = true }

-- Parses "super+shift+q" into key="q", want={ctrl=false,...,super=true}.
-- Returns nil, err if a part before the last isn't one of KNOWN_MODS, so a
-- typo (e.g. "shft+q") fails loudly at bind time instead of silently
-- registering as if the modifier had never been there.
function M.parse_spec(spec)
  local parts = {}
  for part in spec:gmatch("[^+]+") do parts[#parts + 1] = part end
  local want = { ctrl = false, alt = false, shift = false, super = false }
  local key = parts[#parts]
  for i = 1, #parts - 1 do
    local mod = parts[i]
    if not KNOWN_MODS[mod] then
      return nil, "unknown modifier '" .. mod .. "' in keybinding '" .. spec .. "'"
    end
    want[mod] = true
  end
  return key, want
end

-- Compares an event's mods against a parsed `want` table. A missing key in
-- `mods` (nil, rather than false) must count as "not held", never fail the
-- whole comparison outright.
local function mods_match(mods, want)
  return (mods.ctrl or false) == want.ctrl and (mods.alt or false) == want.alt
    and (mods.shift or false) == want.shift and (mods.super or false) == want.super
end

local function focused_window(state)
  return state.focus and state.windows[state.focus] or nil
end

function M.dispatch(e)
  local state = aster.state
  local wm = state.wm

  if e.type == "key_down" then
    -- Two global bindings that bypass wm.keybindings entirely, so they
    -- work even with a broken or empty config (spec §6.5/§6.6): the
    -- explicit reload shortcut, and Escape dismissing the error bubble.
    if e.key == "r" and e.mods.super and e.mods.shift then
      aster.reload()
      aster.mark_dirty()
      return
    end
    if e.key == "escape" and state.error_bubble then
      aster.clear_error()
      aster.mark_dirty()
      return
    end
    if wm then
      for spec, fn in pairs(wm.keybindings) do
        local key, want = M.parse_spec(spec)
        if key == e.key and mods_match(e.mods, want) then
          -- Not wm:guard() — there's no win to close here (see B8).
          local ok, err = pcall(fn)
          if not ok then
            aster.log("keybinding '" .. spec .. "' crashed: " .. tostring(err))
          end
          aster.mark_dirty()
          return
        end
      end
    end
    local win = focused_window(state)
    if win and win.app and win.app.key and wm then
      wm:guard(win, win.app.key, win, e.key, e.mods)
    end
    aster.mark_dirty()
  elseif e.type == "text" then
    local win = focused_window(state)
    if win and win.app and win.app.text and wm then
      wm:guard(win, win.app.text, win, e.text)
      aster.mark_dirty()
    end
  elseif e.type == "mouse_down" then
    if e.button ~= "left" or not wm then return end
    local win = wm:window_at(e.x, e.y)
    if not win then return end
    wm:focus_window(win)
    if e.y - win.y < wm.border then
      dragging = { id = win.id, dx = e.x - win.x, dy = e.y - win.y }
    end
    aster.mark_dirty()
  elseif e.type == "mouse_move" then
    if not dragging then return end
    local win = state.windows[dragging.id]
    if not win then
      dragging = nil
      return
    end
    win.x = e.x - dragging.dx
    win.y = e.y - dragging.dy
    aster.mark_dirty()
  elseif e.type == "mouse_up" then
    if e.button == "left" then dragging = nil end
  elseif e.type == "focus" then
    -- Nothing to do: input.lua never tracks modifier state of its own
    -- (mods arrive fresh on every key_down/key_up), so there's nothing
    -- here for a focus event to clear.
  end
end

return M
