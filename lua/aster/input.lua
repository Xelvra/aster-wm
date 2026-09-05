-- lua/aster/input.lua — events to actions. The launcher and key-repeat land
-- with bar.lua/launcher.lua in a later pass; this milestone routes key_down
-- through the keybinding table, then to the focused window, text to the
-- focused window only (spec/host-contract.md keeps key and text as two
-- separate events on purpose), and mouse to window focus/raise/drag.
-- There is no per-app mouse callback yet — apps only get draw/key/text/tick
-- (spec/architecture.md "Windows and apps") — so a click that isn't on a
-- window's border frame just focuses it.

local M = {}

-- Set while dragging a window by its border; not part of aster.state since
-- it's transient input state, not something a config reload should see.
local dragging = nil

local function spec_matches(spec, key, mods)
  local parts = {}
  for part in spec:gmatch("[^+]+") do parts[#parts + 1] = part end
  local want = { ctrl = false, alt = false, shift = false, super = false }
  local want_key = parts[#parts]
  for i = 1, #parts - 1 do want[parts[i]] = true end
  if key ~= want_key then return false end
  return mods.ctrl == want.ctrl and mods.alt == want.alt
    and mods.shift == want.shift and mods.super == want.super
end

local function focused_window(state)
  return state.focus and state.windows[state.focus] or nil
end

function M.dispatch(e)
  local aster = require("aster")
  local state = aster.state
  local wm = state.wm

  if e.type == "key_down" then
    if wm then
      for spec, fn in pairs(wm.keybindings) do
        if spec_matches(spec, e.key, e.mods) then
          fn()
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
