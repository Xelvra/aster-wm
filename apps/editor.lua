-- apps/editor.lua — a plain-text file editor. Opened with a path in
-- win.state (wm:open{app=editor, state={path=...}}); state lives in
-- win.state, not globals (two instances of this app side by side edit
-- independently, and reload — ADR-003 — never touches an open window's
-- state, so unsaved edits survive a hot reload for free).
--
-- IO is whole-file: host.read(path) once on first draw, host.write(path,
-- content) on Ctrl+S — host.write is already atomic (host-contract.md), so
-- there's no partial-write case to guard against. No file handles, no
-- open/close/truncate.

local r = require("aster.render")
local aster = require("aster")

-- No fixed glyph-width constant anywhere below (D6 in the M6 review):
-- every cursor/scroll position is measured with r.text_width against the
-- ACTUAL text, so this looks right under both the TTF font and the bitmap
-- fallback, whichever the backend ends up using.

-- apps/*.lua may require aster.wm — only lua/aster/ itself is forbidden
-- from knowing an app's name (ADR-007); the reverse has no such rule.
-- draw(win, surface) has no wm reference, so this assumes
-- default_theme's own title_h/border (a real wm instance could in
-- principle be adopted with a different border — see default_theme's own
-- comment on the field) instead of reading the live geometry
-- title_bar_rect(win) uses. TOP_MARGIN = title_h + border puts the first
-- row of content flush against the title bar's actual bottom edge (its
-- own y is win.y + border, see lua/aster/wm.lua's title_bar_rect) — not a
-- few extra px of assumed breathing room, which just leaves a gap the
-- window's own content never paints over (see B42 in
-- spec/troubleshooting.md). That's geometry, fixed at load time; colors
-- are read fresh in draw() below since the theme can change at runtime.
local default_theme = require("aster.wm").default_theme
local TOP_MARGIN = default_theme.title_h + default_theme.border
local ROW_H = 18

local M = {}
M.name = "editor"

-- ---- UTF-8-aware column helpers (byte offsets, 1-based: the cursor sits
-- immediately before byte `col`, so `col` ranges 1..#line+1) -------------

local function is_cont_byte(b)
  return b ~= nil and (b & 0xc0) == 0x80
end

local function cp_len_at(line, col)
  local b = line:byte(col)
  if not b then return 1 end
  if b < 0x80 then return 1
  elseif b & 0xe0 == 0xc0 then return 2
  elseif b & 0xf0 == 0xe0 then return 3
  elseif b & 0xf8 == 0xf0 then return 4
  else return 1 end
end

local function cp_next_col(line, col)
  if col > #line then return col end
  return col + cp_len_at(line, col)
end

local function cp_prev_col(line, col)
  if col <= 1 then return 1 end
  local i = col - 1
  while i > 1 and is_cont_byte(line:byte(i)) do i = i - 1 end
  return i
end

-- ---- state ---------------------------------------------------------------

local function ensure_loaded(win)
  local st = win.state
  if st.lines then return end
  local content = st.path and host.read(st.path)
  st.lines = {}
  for line in (content or ""):gmatch("([^\n]*)\n?") do
    st.lines[#st.lines + 1] = line
  end
  if #st.lines == 0 then st.lines = { "" } end
  st.row, st.col = 1, 1
  st.scroll_row, st.scroll_col = 1, 1
  st.dirty = false
end

local function save(win)
  local st = win.state
  if not st.path then
    aster.log("editor: no path to save to")
    return
  end
  local ok, err = host.write(st.path, table.concat(st.lines, "\n"))
  if ok then
    st.dirty = false
  else
    aster.log("editor: save to " .. st.path .. " failed: " .. tostring(err))
  end
end

-- ---- editing ---------------------------------------------------------------

function M.key(win, key, mods)
  ensure_loaded(win)
  local st = win.state
  local line = st.lines[st.row]

  if mods.ctrl and key == "s" then
    save(win)
  elseif key == "left" then
    if st.col > 1 then
      st.col = cp_prev_col(line, st.col)
    elseif st.row > 1 then
      st.row = st.row - 1
      st.col = #st.lines[st.row] + 1
    end
  elseif key == "right" then
    if st.col <= #line then
      st.col = cp_next_col(line, st.col)
    elseif st.row < #st.lines then
      st.row = st.row + 1
      st.col = 1
    end
  elseif key == "up" then
    if st.row > 1 then
      st.row = st.row - 1
      st.col = math.min(st.col, #st.lines[st.row] + 1)
    end
  elseif key == "down" then
    if st.row < #st.lines then
      st.row = st.row + 1
      st.col = math.min(st.col, #st.lines[st.row] + 1)
    end
  elseif key == "home" then
    st.col = 1
  elseif key == "end" then
    st.col = #line + 1
  elseif key == "backspace" then
    if st.col > 1 then
      local prev = cp_prev_col(line, st.col)
      st.lines[st.row] = line:sub(1, prev - 1) .. line:sub(st.col)
      st.col = prev
      st.dirty = true
    elseif st.row > 1 then
      local prev_line = st.lines[st.row - 1]
      st.col = #prev_line + 1
      st.lines[st.row - 1] = prev_line .. line
      table.remove(st.lines, st.row)
      st.row = st.row - 1
      st.dirty = true
    end
  elseif key == "delete" then
    if st.col <= #line then
      local nxt = cp_next_col(line, st.col)
      st.lines[st.row] = line:sub(1, st.col - 1) .. line:sub(nxt)
      st.dirty = true
    elseif st.row < #st.lines then
      st.lines[st.row] = line .. st.lines[st.row + 1]
      table.remove(st.lines, st.row + 1)
      st.dirty = true
    end
  elseif key == "enter" then
    local rest = line:sub(st.col)
    st.lines[st.row] = line:sub(1, st.col - 1)
    table.insert(st.lines, st.row + 1, rest)
    st.row = st.row + 1
    st.col = 1
    st.dirty = true
  end
  aster.mark_dirty()
end

function M.text(win, str)
  ensure_loaded(win)
  local st = win.state
  local line = st.lines[st.row]
  st.lines[st.row] = line:sub(1, st.col - 1) .. str .. line:sub(st.col)
  st.col = st.col + #str
  st.dirty = true
  aster.mark_dirty()
end

-- ---- drawing ---------------------------------------------------------------

-- Advances scroll_col just enough to keep the cursor's pixel position
-- inside [0, visible_w) — measured with r.text_width, never a fixed
-- per-character width (D6).
local function scroll_into_view(st, line, visible_w)
  local cursor_px = r.text_width(line:sub(1, st.col - 1))
  local scroll_px = r.text_width(line:sub(1, st.scroll_col - 1))
  if cursor_px < scroll_px then
    st.scroll_col = st.col
  else
    while r.text_width(line:sub(1, st.col - 1)) - r.text_width(line:sub(1, st.scroll_col - 1)) >= visible_w
        and st.scroll_col < st.col do
      st.scroll_col = cp_next_col(line, st.scroll_col)
    end
  end
end

function M.draw(win, surface)
  ensure_loaded(win)
  local st = win.state
  local theme = aster.state.wm and aster.state.wm.theme or default_theme

  -- Fills its own background before drawing on top of it; see B47.
  r.fill_rect(surface, win.x, win.y + TOP_MARGIN, win.w, win.h - TOP_MARGIN, theme.surface)

  local tx, ty = win.x + 8, win.y + TOP_MARGIN
  local visible_w = win.w - 16
  local content_rows = math.max(1, math.floor((win.h - TOP_MARGIN - 8) / ROW_H))

  if st.row < st.scroll_row then st.scroll_row = st.row end
  if st.row >= st.scroll_row + content_rows then st.scroll_row = st.row - content_rows + 1 end
  scroll_into_view(st, st.lines[st.row], visible_w)

  for i = 0, content_rows - 1 do
    local line_no = st.scroll_row + i
    local line = st.lines[line_no]
    if not line then break end
    -- st.scroll_col only ever moves to keep the CURSOR's own line's cursor
    -- position in view (scroll_into_view above) — applying it to every
    -- line would shift the whole document sideways for a long line
    -- elsewhere on screen, not the one the cursor is actually on. Every
    -- other line always renders from its own column 1; letting it run
    -- past the right edge is fine; the window's own clip already stops
    -- there.
    local visible = (line_no == st.row) and line:sub(st.scroll_col) or line
    r.text(surface, tx, ty + i * ROW_H, visible, theme.text)
    if line_no == st.row then
      local cursor_x = tx + r.text_width(line:sub(st.scroll_col, st.col - 1))
      r.fill_rect(surface, cursor_x, ty + i * ROW_H, 2, r.line_height(), theme.accent)
    end
  end

  win.title = (st.dirty and "*" or "") .. (st.path or "untitled")
end

return M
