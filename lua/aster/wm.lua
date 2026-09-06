-- lua/aster/wm.lua — windows, ids, focus. Every window has a stable
-- integer id (spec/architecture.md "Windows and apps"); tiling/workspaces
-- are not implemented yet — every window is floating, and `wm:open` never
-- sets `ws`.

local M = {}
local aster = require("aster")

function M.default_draw_frame(self, win, surface)
  local r = require("aster.render")
  local color = win.focused and (self.theme.accent or 0xff5544) or (self.theme.inactive or 0x3b4248)
  r.rect_border(surface, win.x, win.y, win.w, win.h, self.border, color)
end

-- adopt(opts): first call creates the singleton wm and stores it in
-- aster.state.wm; every later call (i.e. every reload) returns the SAME
-- instance, after resetting everything a previous config could have
-- overridden (spec/architecture.md "Reload preserves state").
function M.adopt(opts)
  opts = opts or {}
  aster.state.wm = aster.state.wm or setmetatable({}, { __index = M })
  local wm = aster.state.wm

  wm.gaps = opts.gaps or { outer = 0, inner = 0 }
  wm.border = opts.border or 2
  wm.layout = opts.layout or "float"
  wm.keybindings = {}
  -- ADR-003 names theme among what a reload must reset: removing a
  -- `wm.theme = {...}` line from the config must actually remove its
  -- effect, not leave the last-seen theme stuck.
  wm.theme = opts.theme or {}
  wm.draw_frame = M.default_draw_frame

  return wm
end

function M:bind(spec, fn)
  local input = require("aster.input")
  local key, err = input.parse_spec(spec)
  if not key then
    aster.log("wm:bind: " .. err .. " — binding not registered")
    return
  end
  self.keybindings[spec] = fn
end

-- The only place a window is created. Launcher, keybinding and an app
-- itself all call this the same way — no privileged path.
function M:open(opts)
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
  local state = aster.state
  state.windows[win.id] = nil
  if state.focus == win.id then
    -- Hand focus to whatever's now on top, so the keyboard doesn't go dead
    -- just because the previously-focused window closed.
    local next_win, next_z = nil, -1
    for _, w in pairs(state.windows) do
      if w.z > next_z then next_win, next_z = w, w.z end
    end
    state.focus = next_win and next_win.id or nil
  end
end

-- Topmost window whose bounds contain (x, y), or nil.
function M:window_at(x, y)
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
  local state = aster.state
  win.z = state.next_z
  state.next_z = state.next_z + 1
  state.focus = win.id
end

-- Calls an app callback under pcall. An app that throws closes its own
-- window and logs — it never takes the desktop down with it
-- (spec/architecture.md "Windows and apps"). Returns what pcall returns:
-- ok, and fn's result on success.
function M:guard(win, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    aster.log("app '" .. tostring(win.title) .. "' crashed: " .. tostring(result))
    self:close(win)
    return false
  end
  return true, result
end

-- Calls self:draw_frame(win, surface) under pcall, separately from guard():
-- a crash here is the config's fault, not the app's, so it must not close
-- the window — instead fall back to the built-in frame for good and keep
-- going (see B7). Takes `surface` as an argument, the same way app.draw
-- does, rather than reading it off `self` — one calling convention for
-- both kinds of draw callback.
function M:render_frame(win, surface)
  local ok, err = pcall(self.draw_frame, self, win, surface)
  if not ok then
    aster.log("wm.lua draw_frame crashed: " .. tostring(err) .. " — falling back to the built-in frame")
    self.draw_frame = M.default_draw_frame
    pcall(self.draw_frame, self, win, surface)
  end
end

local BUBBLE_MAX_WIDTH = 480
local BUBBLE_MAX_LINES = 6

-- Iterates `s` one UTF-8 codepoint (as a Lua byte-substring) at a time, so
-- callers never have to slice mid-sequence.
local function each_codepoint(s)
  local i = 1
  return function()
    if i > #s then return nil end
    local b = s:byte(i)
    local len = 1
    if b >= 0xf0 then
      len = 4
    elseif b >= 0xe0 then
      len = 3
    elseif b >= 0xc0 then
      len = 2
    end
    local cp = s:sub(i, i + len - 1)
    i = i + len
    return cp
  end
end

-- Breaks `text` into lines no wider than `max_w`, greedily packing words; a
-- single word wider than `max_w` on its own (no spaces to break on) is
-- hard-split instead of overrunning it, on a codepoint boundary (never
-- mid-UTF-8-sequence, which would draw as U+FFFD) and in one linear pass
-- per split (not re-measuring the accumulated prefix from scratch on every
-- codepoint, which is what made this quadratic in word length — see B22 in
-- spec/troubleshooting.md).
local function wrap_line(r, text, max_w)
  if r.text_width(text) <= max_w then return { text } end
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    while r.text_width(word) > max_w do
      local piece, width = "", 0
      for cp in each_codepoint(word) do
        local cpw = r.text_width(cp)
        if width + cpw > max_w and piece ~= "" then break end
        piece = piece .. cp
        width = width + cpw
      end
      if piece == "" then piece = word:sub(1, 1) end -- one codepoint alone already overruns max_w; take it anyway so progress is guaranteed
      if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
      lines[#lines + 1] = piece
      word = word:sub(#piece + 1)
    end
    local candidate = cur == "" and word or (cur .. " " .. word)
    if r.text_width(candidate) <= max_w then
      cur = candidate
    else
      lines[#lines + 1] = cur
      cur = word
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

-- ADR-003's error bubble: a bordered box in the top-right corner, drawn
-- last so it sits above every window. Two lines for a compile/runtime
-- error (the error itself, then "desktop untouched"); one line for the
-- built-in-default fallback, which has no "previous config" left to name.
-- Wrapped to a fixed max width and capped at a fixed max line count (see
-- B11) so a long error message can't overrun the screen or the box.
local function render_error_bubble(surface, out, bubble)
  local r = require("aster.render")
  local pad, margin = 12, 16
  local lh = r.line_height()
  local max_w = math.min(BUBBLE_MAX_WIDTH, out.w - pad * 2 - margin * 2)

  local lines = {}
  for _, raw in ipairs(bubble.line2 and { bubble.line1, bubble.line2 } or { bubble.line1 }) do
    for _, wrapped in ipairs(wrap_line(r, raw, max_w)) do
      lines[#lines + 1] = wrapped
    end
  end
  if #lines > BUBBLE_MAX_LINES then
    for i = #lines, BUBBLE_MAX_LINES + 1, -1 do lines[i] = nil end
    lines[BUBBLE_MAX_LINES] = "..."
  end

  local w = 0
  for _, line in ipairs(lines) do w = math.max(w, r.text_width(line)) end
  w = w + pad * 2
  local h = #lines * lh + pad * 2
  local x = out.w - w - margin
  local y = margin

  r.fill_rect(surface, x, y, w, h, 0x2a1414)
  r.rect_border(surface, x, y, w, h, 2, 0xcc4444)
  for i, line in ipairs(lines) do
    r.text(surface, x + pad, y + pad + (i - 1) * lh, line, 0xf0d0d0)
  end
end

function M:render(surface)
  local r = require("aster.render")
  local state = aster.state
  local out = state.info.outputs[1]

  r.fill_rect(surface, 0, 0, out.w, out.h, self.theme.background or 0x111111)

  -- pairs() has no defined order; paint back-to-front by z so the topmost
  -- window (highest z, per focus_window/window_at) is also drawn last.
  local ordered = {}
  for _, win in pairs(state.windows) do ordered[#ordered + 1] = win end
  table.sort(ordered, function(a, b) return a.z < b.z end)

  for _, win in ipairs(ordered) do
    win.focused = (state.focus == win.id)
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
    if not crashed then self:render_frame(win, surface) end
  end

  if state.error_bubble then
    render_error_bubble(surface, out, state.error_bubble)
  end
end

-- Calls win.app.tick(win, now_ms) for every window (spec/architecture.md
-- "Windows and apps", the optional fourth app callback); a truthy return
-- marks the frame dirty.
function M:tick(now_ms)
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
