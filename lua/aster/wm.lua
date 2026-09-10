-- lua/aster/wm.lua — windows, ids, focus, workspaces. Every window has a
-- stable integer id (spec/architecture.md "Windows and apps"); tiling is
-- not implemented — every window is floating, positioned by x/y/w/h only.

local M = {}
local aster = require("aster")

-- One place for every default color, instead of a different
-- `self.theme.accent or 0xff5544`-style fallback at each call site — a
-- theme (or a config) missing a key used to get whatever literal that
-- call site happened to hard-code, which drifted between wm.lua's two own
-- copies and init.lua's built-in fallback screen. Values are a direct port
-- of aster-os's own theme.lua (background/surface/surface_alt/text/
-- text_dim/accent/accent_b/accent_dark/inactive/red, plus
-- opacity_active/opacity_inactive) — this is meant to look like that
-- desktop, not a new palette. `title_h`, `radius`, `shadow` are geometry
-- this milestone added beyond what aster-os had; `radius = 0` keeps the
-- default frame's corners sharp like the original, but a theme can set it.
M.default_theme = {
  background = 0x111826,
  surface = 0x182545,
  surface_alt = 0x223454,
  text = 0xdddddd,
  text_dim = 0x798bb2,
  accent = 0x82dccc,
  accent_b = 0x00aa84,
  accent_dark = 0x007d6f,
  inactive = 0x798bb2,
  red = 0xff6b6b,
  opacity_active = 0.95, -- 0-1, blended into the title bar background
  opacity_inactive = 0.85,
  title_h = 24, -- title bar height, pixels
  radius = 0, -- window corner radius, pixels — 0 matches aster-os's sharp frame
  shadow = 0, -- drop shadow peak alpha, 0-255 (aster-os drew none)
  -- Not itself read by title_bar_rect below (that uses the live `self.border`
  -- a wm instance was actually adopted with, e.g. config/wm.lua's
  -- `border = 2`) — this is here so an app's draw(win, surface), which has
  -- no wm reference to read the real value from, has a documented default
  -- to assume instead of guessing. Every apps/*.lua's own TOP_MARGIN is
  -- `title_h + border`: exactly the title bar's own bottom edge
  -- (title_bar_rect's `y + h`, with `y` itself `win.y + border`), so an
  -- app's content starts flush against it — no gap the background behind
  -- the window (or, until it's drawn, another window under it) shows
  -- through, no overlap with the title bar's own text either.
  border = 2,
}

-- title_bar_rect/close_button_rect are shared by drawing (default_draw_frame
-- below) and hit-testing (lua/aster/input.lua's drag-start and close-click)
-- so the two can never drift apart — the click target is always exactly
-- what got drawn. win.x/y/w/h stays the app's whole content rect
-- (spec/architecture.md rule 3's contract doesn't change); the title bar is
-- chrome painted over the top of it, not carved out of it — aster has no
-- rounded-rect clip mask, so "carving" a smaller content area would need
-- renderer work this block doesn't do.
function M:title_bar_rect(win)
  local t = self.border
  return { x = win.x + t, y = win.y + t, w = win.w - 2 * t, h = self.theme.title_h }
end

function M:close_button_rect(win)
  local tb = self:title_bar_rect(win)
  local size = math.min(16, tb.h - 6)
  return { x = tb.x + tb.w - size - 6, y = tb.y + math.floor((tb.h - size) / 2), w = size, h = size }
end

local function lerp_channel(a, b, t)
  return math.floor(a + (b - a) * t + 0.5)
end

local function lerp_color(a, b, t)
  local ar, ag, ab = (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff
  local br, bg, bb = (b >> 16) & 0xff, (b >> 8) & 0xff, b & 0xff
  return (lerp_channel(ar, br, t) << 16) | (lerp_channel(ag, bg, t) << 8) | lerp_channel(ab, bb, t)
end

-- aster-os's `blend(color, factor)`: an OPAQUE color interpolated toward
-- theme.background, not an alpha composite over whatever's already drawn.
-- The close button needs this rather than fill_rect's alpha parameter
-- because it sits on a title bar that's the same theme.surface_alt color
-- as the button itself — alpha-over-current-pixel there blends a color
-- into an identical color and produces no visible contrast at all.
local function blend_toward_background(theme, color, factor)
  return lerp_color(theme.background, color, factor)
end

local FOCUS_ANIM_MS = 120

-- 0 (just changed) to 1 (settled): win._focus_t0/_prev_focused are set by
-- M:render as it notices win.focused changed, so this needs no separate
-- per-frame ticking of its own. M:render marks the frame dirty while any
-- window is still short of 1 here — without F5's frame limiter
-- (spec/troubleshooting.md B34) that would pin a core for 120ms on every
-- focus change, the same class of bug B34 fixed for an app's own `tick`.
local function focus_progress(win)
  if not win._focus_t0 then return 1 end
  local elapsed = host.now_ms() - win._focus_t0
  if elapsed >= FOCUS_ANIM_MS then return 1 end
  return elapsed / FOCUS_ANIM_MS
end

-- Draws `color` as a `thickness`-px ring around the outer edge of
-- x,y,w,h, with `radius`-px rounded corners, WITHOUT touching anything
-- inside it — necessary because r.round_rect fills a solid shape, and the
-- window's own content is already painted inside this rect by the time
-- default_draw_frame runs. Four narrow push_clip bands
-- (each covering one edge, all the way into both its corners) restrict
-- each round_rect call to just that band; round_rect still sees the FULL
-- x,y,w,h,radius so the corner curvature comes out right where two bands
-- overlap. See roundRect's own comment in src/render/renderer.zig for why
-- it clips internally too — without that, this would cost the whole
-- window's pixel count four times over just to draw a thin ring.
local function draw_rounded_ring(r, surface, x, y, w, h, radius, thickness, color)
  local t = thickness
  r.push_clip(surface, x, y, w, t) -- top
  r.round_rect(surface, x, y, w, h, radius, color)
  r.pop_clip(surface)
  r.push_clip(surface, x, y + h - t, w, t) -- bottom
  r.round_rect(surface, x, y, w, h, radius, color)
  r.pop_clip(surface)
  r.push_clip(surface, x, y, t, h) -- left
  r.round_rect(surface, x, y, w, h, radius, color)
  r.pop_clip(surface)
  r.push_clip(surface, x + w - t, y, t, h) -- right
  r.round_rect(surface, x, y, w, h, radius, color)
  r.pop_clip(surface)
end

-- The border, the title bar band with the window's title, and a close
-- button — all as one overridable hook (spec/code-style.md's "policy up"
-- — a config rewrites this whole function, not individual pieces of it,
-- see rewrite-frame.gif). A direct visual port of aster-os's own
-- win_render: `theme.radius == 0` (the default) draws the exact same
-- shape it did — a two-color gradient border on the focused window
-- (r.gradient_border, accent -> accent_dark), a plain one-color border
-- otherwise, a filled title bar blended toward whatever's behind it by
-- opacity_active/opacity_inactive, and a close button shown only on the
-- focused window. `theme.radius > 0` (opt-in, not the default) switches
-- to the rounded-ring path instead — gradient_border has no rounded
-- counterpart, so a rounded frame trades the gradient for a solid,
-- animated border color.
function M.default_draw_frame(self, win, surface)
  local r = require("aster.render")
  local theme = self.theme
  local progress = focus_progress(win)

  if theme.radius > 0 then
    local target = win.focused and theme.accent or theme.inactive
    local origin = win.focused and theme.inactive or theme.accent
    local border_color = lerp_color(origin, target, progress)
    draw_rounded_ring(r, surface, win.x, win.y, win.w, win.h, theme.radius, self.border, border_color)
  elseif win.focused and progress >= 1 then
    r.gradient_border(surface, win.x, win.y, win.w, win.h, self.border, theme.accent, theme.accent_dark)
  else
    local target = win.focused and theme.accent or theme.inactive
    local origin = win.focused and theme.inactive or theme.accent
    local border_color = lerp_color(origin, target, progress)
    r.rect_border(surface, win.x, win.y, win.w, win.h, self.border, border_color)
  end

  local tb = self:title_bar_rect(win)
  local title_bg = win.focused and theme.surface_alt or theme.surface
  local opacity = win.focused and theme.opacity_active or theme.opacity_inactive
  r.fill_rect(surface, tb.x, tb.y, tb.w, tb.h, title_bg, math.floor(opacity * 255 + 0.5))
  local title_color = win.focused and theme.text or theme.text_dim
  r.text(surface, tb.x + 6, tb.y + math.floor((tb.h - r.line_height()) / 2), win.title or "", title_color)

  -- Only the focused window shows a close button — matches aster-os,
  -- and means an unfocused window's title bar never collides with one.
  if win.focused then
    local cb = self:close_button_rect(win)
    r.fill_rect(surface, cb.x, cb.y, cb.w, cb.h, blend_toward_background(theme, theme.surface_alt, 0.7))
    r.text(surface, cb.x + math.floor((cb.w - r.text_width("x")) / 2),
      cb.y + math.floor((cb.h - r.line_height()) / 2), "x", theme.text)
  end
end

-- Two soft, offset layers rather than one hard-edged one — composed from
-- alpha fill_rect/round_rect calls in Lua, never a renderer-side
-- `shadow()` (spec/architecture.md rule 3: the renderer never learns what
-- a shadow is, only how to blend a rect). `theme.shadow == 0` disables it
-- outright rather than drawing a fully-transparent no-op.
local function draw_shadow(r, surface, win, theme)
  if theme.shadow <= 0 then return end
  r.round_rect(surface, win.x + 6, win.y + 8, win.w, win.h, theme.radius, 0x000000, math.floor(theme.shadow / 3))
  r.round_rect(surface, win.x + 3, win.y + 4, win.w, win.h, theme.radius, 0x000000, math.floor(theme.shadow * 2 / 3))
end

-- Every `wm.theme = {...}` assignment (adopt() below, and any config or
-- theme module afterward) is wrapped so a key that table doesn't set falls
-- through to M.default_theme, instead of coming back nil. A theme file can
-- therefore override just `accent` and inherit everything else. Applies to
-- the *whole* table each time it's replaced (not merged in place), so
-- ADR-003's "reload resets" still holds: a config that stops setting
-- `wm.theme` entirely goes back to all-defaults, not a stale mix.
--
-- `theme` is deliberately never stored as a real field on the wm table
-- itself (kept in this weak side table instead) — see B35 in
-- spec/troubleshooting.md: a plain `rawset` is only intercepted by
-- __newindex on the *first* assignment, so a config's own later
-- `wm.theme = {...}` (an ordinary assignment to an already-existing key)
-- would silently skip the wrap entirely.
local theme_storage = setmetatable({}, { __mode = "k" })

local wm_mt = {
  __index = function(t, k)
    if k == "theme" then return theme_storage[t] end
    return M[k]
  end,
  __newindex = function(t, k, v)
    if k == "theme" then
      if type(v) == "table" then
        v = setmetatable(v, { __index = M.default_theme })
      end
      theme_storage[t] = v
      return
    end
    rawset(t, k, v)
  end,
}

-- adopt(opts): first call creates the singleton wm and stores it in
-- aster.state.wm; every later call (i.e. every reload) returns the SAME
-- instance, after resetting everything a previous config could have
-- overridden (spec/architecture.md "Reload preserves state").
function M.adopt(opts)
  opts = opts or {}
  aster.state.wm = aster.state.wm or setmetatable({}, wm_mt)
  local wm = aster.state.wm

  wm.gaps = opts.gaps or { outer = 0, inner = 0 }
  wm.border = opts.border or 2
  wm.layout = opts.layout or "float"
  wm.keybindings = {}
  -- ADR-003 names theme among what a reload must reset: removing a
  -- `wm.theme = {...}` line from the config must actually remove its
  -- effect, not leave the last-seen override stuck.
  wm.theme = opts.theme or {}
  wm.draw_frame = M.default_draw_frame
  -- Same ADR-003 reasoning as theme: a config that stops setting `wm.bar`
  -- after adopt() must actually lose the bar, not leave a stale one from
  -- the previous config's reload drawing itself forever.
  wm.bar = opts.bar or nil
  wm.launcher = opts.launcher or nil

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
-- aster.state.current_ws defaults to 1 rather than being required at boot,
-- so old state (a reload from before workspaces existed, or a test that
-- never sets it) still behaves like "everything is on workspace 1", not a
-- crash on a nil comparison.
function M:current_ws()
  return aster.state.current_ws or 1
end

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
    ws = opts.ws or self:current_ws(),
    -- opts.state seeds the app's own per-window state (e.g. apps/editor.lua's
    -- initial path) — app-owned from here on, wm never reads or writes into
    -- it itself.
    state = opts.state or {},
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
    -- Hand focus to whatever's now on top ON THE SAME WORKSPACE, so the
    -- keyboard doesn't go dead just because the previously-focused window
    -- closed, and doesn't jump to a window the user can't currently see.
    local next_win, next_z = nil, -1
    for _, w in pairs(state.windows) do
      if (w.ws or 1) == self:current_ws() and w.z > next_z then next_win, next_z = w, w.z end
    end
    state.focus = next_win and next_win.id or nil
  end
end

-- Double-click on a title bar (lua/aster/input.lua) toggles between the
-- window's own x/y/w/h and filling the whole screen (minus the bar and
-- the usual outer gap — the same area config/wm.lua's own default-window
-- geometry fills). `win._premax`, not a separate `win.maximized` flag,
-- both marks "currently maximized" AND is the geometry to snap back to —
-- one field, so there's no way for the flag and the saved rect to drift
-- out of sync with each other.
function M:toggle_maximize(win)
  if not win then return end
  if win._premax then
    win.x, win.y, win.w, win.h = win._premax.x, win._premax.y, win._premax.w, win._premax.h
    win._premax = nil
  else
    win._premax = { x = win.x, y = win.y, w = win.w, h = win.h }
    local out = aster.state.info.outputs[1]
    local gout = self.gaps.outer
    local bar_h = self.bar and self.bar.height or 0
    win.x, win.y = gout, bar_h + gout
    win.w, win.h = out.w - 2 * gout, out.h - bar_h - 2 * gout
  end
end

-- Topmost window on the current workspace whose bounds contain (x, y), or
-- nil — a window on another (invisible) workspace is never a click target.
function M:window_at(x, y)
  local state = aster.state
  local best, best_z = nil, -1
  for _, win in pairs(state.windows) do
    if (win.ws or 1) == self:current_ws()
        and x >= win.x and x < win.x + win.w and y >= win.y and y < win.y + win.h then
      if win.z > best_z then
        best, best_z = win, win.z
      end
    end
  end
  return best
end

-- Switches the visible workspace and refocuses to whatever's now on top
-- there (nil if it's empty) — the keyboard should never stay pointed at a
-- window that just became invisible.
function M:goto_workspace(i)
  local state = aster.state
  state.current_ws = i
  local top, top_z = nil, -1
  for _, w in pairs(state.windows) do
    if (w.ws or 1) == i and w.z > top_z then top, top_z = w, w.z end
  end
  state.focus = top and top.id or nil
  aster.mark_dirty()
end

function M:move_to_workspace(win, i)
  if not win then return end
  win.ws = i
  aster.mark_dirty()
end

-- How many workspace bubbles the bar should show: at least 2 (the user's
-- requested minimum convention, rather than aster-os's arbitrary fixed
-- list), never fewer than whichever one is current — same aster.state
-- field workspace_widget.lua's "+" bubble advances via add_workspace().
-- Lives in aster.state, not a local var here, because ADR-003 counts
-- workspaces as part of what a reload preserves, same as windows/focus.
function M:workspace_count()
  return math.max(aster.state.ws_count or 2, self:current_ws())
end

-- The bar's "+" bubble: makes a new, empty workspace one past the highest
-- one currently shown, and switches to it.
function M:add_workspace()
  aster.state.ws_count = self:workspace_count() + 1
  self:goto_workspace(aster.state.ws_count)
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

  r.fill_rect(surface, 0, 0, out.w, out.h, self.theme.background)

  -- pairs() has no defined order; paint back-to-front by z so the topmost
  -- window (highest z, per focus_window/window_at) is also drawn last.
  -- Only the current workspace's windows: a hidden workspace's windows
  -- stay exactly as they were until it's switched back to (no tiling/
  -- layout recompute happens off-screen either).
  local ordered = {}
  local current_ws = self:current_ws()
  for _, win in pairs(state.windows) do
    if (win.ws or 1) == current_ws then ordered[#ordered + 1] = win end
  end
  table.sort(ordered, function(a, b) return a.z < b.z end)

  for _, win in ipairs(ordered) do
    win.focused = (state.focus == win.id)
    if win.focused ~= win._prev_focused then
      win._focus_t0 = host.now_ms()
      win._prev_focused = win.focused
    end
    if focus_progress(win) < 1 then aster.mark_dirty() end

    draw_shadow(r, surface, win, self.theme)
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

  -- Drawn last, on top of every window (no gaps-aware layout reserves
  -- space for it yet — a window can end up underneath it, same floating-
  -- only limitation spec/architecture.md already documents).
  if self.bar then self.bar:render(surface) end

  if state.error_bubble then
    render_error_bubble(surface, out, state.error_bubble)
  end

  -- Topmost of all: a modal-ish popup over everything, including the bar.
  if self.launcher then self.launcher:render(surface) end
end

-- Calls win.app.tick(win, now_ms) for every window on the current
-- workspace (spec/architecture.md "Windows and apps", the optional fourth
-- app callback); a truthy return marks the frame dirty. Windows on a
-- hidden workspace don't tick: nothing they could mark_dirty() over is
-- visible anyway, and it would just repaint whatever workspace IS visible
-- for a change nobody can see.
function M:tick(now_ms)
  local state = aster.state
  local current_ws = self:current_ws()
  for _, win in pairs(state.windows) do
    if (win.ws or 1) == current_ws and win.app and win.app.tick then
      local ok, want_redraw = self:guard(win, win.app.tick, win, now_ms)
      if ok and want_redraw then
        aster.mark_dirty()
      end
    end
  end
end

return M
