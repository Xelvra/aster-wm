-- lua/aster/input.lua — events to actions. Routes key_down through the
-- keybinding table, then to the focused window; text to the focused window
-- only (spec/host-contract.md keeps key and text as two separate events on
-- purpose). A mouse_down is routed in order: the launcher, while it's open,
-- owns every click (click away to dismiss, click a list item, nothing else
-- reaches through it); then a bar widget; then focus/raise the window under
-- the click; then, within that window, the close button, the title bar
-- (drag, or double-click to maximize), and otherwise `win.app.click`
-- (spec/architecture.md "Windows and apps") for a click on its content.
-- key_up and scroll events are received but not yet routed anywhere; an
-- app never sees them.

local M = {}
local aster = require("aster")

-- Set while dragging a window by its border; not part of aster.state since
-- it's transient input state, not something a config reload should see.
local dragging = nil

-- Double-click-to-maximize's own click-tracking state — same "transient,
-- not aster.state" reasoning as `dragging`. A second title-bar click on
-- the SAME window within DOUBLE_CLICK_MS counts; anywhere else, or too
-- slow, and it's just two single clicks.
local DOUBLE_CLICK_MS = 400
local last_title_click = nil -- { id = win.id, t = host.now_ms() }

-- The only modifier names a keybinding spec may use (spec/keys.md is
-- normative for key names; this is the equivalent list for modifiers).
local KNOWN_MODS = { ctrl = true, alt = true, shift = true, super = true }

-- Parses "super+shift+q" into key="q", want={ctrl=false,...,super=true}.
-- Returns nil, err if a part before the last isn't one of KNOWN_MODS, so a
-- typo (e.g. "shft+q") fails loudly at bind time instead of silently
-- registering as if the modifier had never been there.
local function parse_spec_uncached(spec)
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

-- parse_spec is pure in `spec` alone, but dispatch() calls it once per
-- registered binding on every single key_down — memoized so a keypress
-- costs a table lookup per binding, not a full re-parse of its spec string.
local parse_cache = {}

function M.parse_spec(spec)
  local cached = parse_cache[spec]
  if not cached then
    cached = { parse_spec_uncached(spec) }
    parse_cache[spec] = cached
  end
  return cached[1], cached[2]
end

-- ADR-003 says a reload resets the keybinding table; this cache is a
-- pure-function memoization of a config's spec strings, so a stale entry
-- can never be *wrong* — but a config that generates spec strings
-- programmatically (e.g. from user config data) would otherwise grow this
-- table across every reload, unbounded. Called from aster.reload().
function M.reset_parse_cache()
  parse_cache = {}
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
    -- work even with a broken or empty config (ADR-003): the explicit
    -- reload shortcut, and Escape dismissing the error bubble. Matched via
    -- mods_match, same as any user keybinding, so Ctrl+Super+Shift+R does
    -- NOT also trigger this (and remains available to bind separately).
    if e.key == "r" and mods_match(e.mods, { ctrl = false, alt = false, shift = true, super = true }) then
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
    -- Routing order: global keybinding (above) > launcher, while it's
    -- open > focused window. The launcher swallows the key outright, even
    -- one that doesn't mean anything to it, so a window underneath never
    -- sees keystrokes meant for the search box.
    if wm and wm.launcher and wm.launcher:is_open() then
      wm.launcher:key(e.key)
      aster.mark_dirty()
      return
    end
    local win = focused_window(state)
    if win and win.app and win.app.key and wm then
      wm:guard(win, win.app.key, win, e.key, e.mods)
    end
    aster.mark_dirty()
  elseif e.type == "text" then
    if wm and wm.launcher and wm.launcher:is_open() then
      wm.launcher:text(e.text)
      aster.mark_dirty()
      return
    end
    local win = focused_window(state)
    if win and win.app and win.app.text and wm then
      wm:guard(win, win.app.text, win, e.text)
      aster.mark_dirty()
    end
  elseif e.type == "mouse_down" then
    if e.button ~= "left" or not wm then return end
    -- While the launcher is open it owns every click: outside its popup
    -- closes it (the usual "click away to dismiss" a modal gets), inside
    -- it does nothing yet (list items aren't clickable — keyboard only).
    -- Either way a click must never reach the bar or a window underneath
    -- while the popup is up.
    if wm.launcher and wm.launcher:is_open() then
      local pr = wm.launcher:popup_rect()
      local cr = wm.launcher:close_rect()
      if (e.x >= cr.x and e.x < cr.x + cr.w and e.y >= cr.y and e.y < cr.y + cr.h)
          or e.x < pr.x or e.x >= pr.x + pr.w or e.y < pr.y or e.y >= pr.y + pr.h then
        wm.launcher:close()
      else
        wm.launcher:click(e.x, e.y)
      end
      aster.mark_dirty()
      return
    end
    if wm.bar and wm.bar:click(e.x, e.y) then
      aster.mark_dirty()
      return
    end
    local win = wm:window_at(e.x, e.y)
    if not win then return end
    wm:focus_window(win)
    -- Same geometry the title bar and close button were just drawn with
    -- (wm:title_bar_rect/close_button_rect, lua/aster/wm.lua) — the click
    -- target can't drift from what's on screen because there's only one
    -- place that computes either rect.
    local cb = wm:close_button_rect(win)
    if e.x >= cb.x and e.x < cb.x + cb.w and e.y >= cb.y and e.y < cb.y + cb.h then
      wm:close(win)
      aster.mark_dirty()
      return
    end
    local tb = wm:title_bar_rect(win)
    if e.y >= tb.y and e.y < tb.y + tb.h then
      local now = host.now_ms()
      if last_title_click and last_title_click.id == win.id and now - last_title_click.t < DOUBLE_CLICK_MS then
        wm:toggle_maximize(win)
        last_title_click = nil
      else
        dragging = { id = win.id, dx = e.x - win.x, dy = e.y - win.y }
        last_title_click = { id = win.id, t = now }
      end
    elseif win.app and win.app.click then
      wm:guard(win, win.app.click, win, e.x, e.y)
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
    -- Never let the title bar itself go up under the bar — once it's
    -- behind the bar there's nothing left to grab (the bar owns clicks in
    -- front of it, wm.bar:click above) and the window is stuck there.
    -- Clamped on win.y directly (not just where the drag started), so
    -- dragging up fast can't punch through it in one big mouse_move jump
    -- either.
    if wm and wm.bar then
      local min_y = wm.bar.height - wm.border
      if win.y < min_y then win.y = min_y end
    end
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
