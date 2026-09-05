-- lua/aster/wm.lua — windows, ids, focus. Tiling/workspaces land later
-- (ASTER-WM.md §12 B.4); this milestone gives every window a stable
-- integer id (spec/architecture.md "Windows and apps") instead of the old
-- dispatch-by-title.

local M = {}

function M.default_draw_frame(self, win)
  local r = require("aster.render")
  local color = win.focused and (self.theme.accent or 0xff5544) or (self.theme.inactive or 0x3b4248)
  r.rect_border(self.surface, win.x, win.y, win.w, win.h, self.border, color)
end

-- adopt(opts): first call creates the singleton wm and stores it in
-- aster.state.wm; every later call (i.e. every reload) returns the SAME
-- instance, after resetting everything a previous config could have
-- overridden (spec/architecture.md "Reload preserves state").
function M.adopt(opts)
  opts = opts or {}
  local aster = require("aster")
  aster.state.wm = aster.state.wm or setmetatable({}, { __index = M })
  local wm = aster.state.wm

  wm.gaps = opts.gaps or { outer = 0, inner = 0 }
  wm.border = opts.border or 2
  wm.layout = opts.layout or "float"
  wm.keybindings = {}
  wm.theme = wm.theme or {}
  wm.draw_frame = M.default_draw_frame

  return wm
end

function M:bind(spec, fn)
  self.keybindings[spec] = fn
end

-- The only place a window is created. Launcher, keybinding and an app
-- itself all call this the same way — no privileged path.
function M:open(opts)
  local aster = require("aster")
  local state = aster.state
  local id = state.next_id
  state.next_id = id + 1

  local win = {
    id = id,
    title = opts.title or (opts.app and opts.app.name) or "window",
    app = opts.app,
    x = opts.x or 40, y = opts.y or 40,
    w = opts.w or 480, h = opts.h or 320,
    floating = true,
    z = state.next_z,
    state = {},
  }
  state.next_z = state.next_z + 1
  state.windows[id] = win
  state.focus = id
  return win
end

function M:close(win)
  if not win then return end
  local aster = require("aster")
  local state = aster.state
  state.windows[win.id] = nil
  if state.focus == win.id then state.focus = nil end
end

-- Topmost window whose bounds contain (x, y), or nil.
function M:window_at(x, y)
  local aster = require("aster")
  local state = aster.state
  local best, best_z = nil, -1
  for _, win in pairs(state.windows) do
    if x >= win.x and x < win.x + win.w and y >= win.y and y < win.y + win.h then
      if win.z > best_z then
        best, best_z = win, win.z
      end
    end
  end
  return best
end

-- Raises a window to the top of the stack and gives it focus.
function M:focus_window(win)
  if not win then return end
  local aster = require("aster")
  local state = aster.state
  win.z = state.next_z
  state.next_z = state.next_z + 1
  state.focus = win.id
end

-- Calls an app callback under pcall. An app that throws closes its own
-- window and logs — it never takes the desktop down with it (spec
-- §7.2: "Appka, která spadne, zavře své okno a zaloguje; nebere s sebou
-- desktop."). Returns what pcall returns: ok, and fn's result on success.
function M:guard(win, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    host.log("aster: app '" .. tostring(win.title) .. "' crashed: " .. tostring(result))
    self:close(win)
    return false
  end
  return true, result
end

function M:render(surface)
  self.surface = surface
  local r = require("aster.render")
  local aster = require("aster")
  local state = aster.state
  local out = aster.info.outputs[1]

  r.fill_rect(surface, 0, 0, out.w, out.h, self.theme.background or 0x111111)

  for id, win in pairs(state.windows) do
    win.focused = (state.focus == id)
    local crashed = false
    if win.app and win.app.draw then
      r.clipped(surface, win.x, win.y, win.w, win.h, function()
        local ok = self:guard(win, win.app.draw, win, surface)
        crashed = not ok
      end)
    end
    -- drawn after the app's content so the frame stays visible on top —
    -- unless guard() just closed this window, in which case there's
    -- nothing left to frame.
    if not crashed then self:draw_frame(win) end
  end
end

-- Calls win.app.tick(win, now_ms) for every window (spec §7.2, the
-- optional fourth app callback); a truthy return marks the frame dirty.
function M:tick(now_ms)
  local aster = require("aster")
  local state = aster.state
  for _, win in pairs(state.windows) do
    if win.app and win.app.tick then
      local ok, want_redraw = self:guard(win, win.app.tick, win, now_ms)
      if ok and want_redraw then
        aster.mark_dirty()
      end
    end
  end
end

return M
