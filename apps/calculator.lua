-- apps/calculator.lua — a real button-grid calculator: a display plus a
-- 4-column, 5-row keypad, a direct visual and behavioral port of
-- aster-os's own calculator.zig (color-coded operator/clear/equals
-- buttons, one operation applied at a time — not an expression
-- evaluator). Mouse (app.click) and keyboard (app.key/app.text) both
-- press the same buttons.
--
-- calculator.zig's own layout ran 4 columns for 3 rows and only widened
-- to 5 for the last one, just to give "." its own key — which left that
-- key sitting off both the horizontal and vertical grid lines every other
-- button aligns to. This is a real 4x4 grid instead: two more function
-- keys (+/-, %) fill row 0 rather than leaving "." as the odd one out,
-- and "0" spans two columns on the bottom row (`span`, below) the way a
-- physical calculator's biggest key usually does — the one button wide
-- enough to need it, not a gap-filler.

local r = require("aster.render")

local M = {}
M.name = "calculator"

-- Same reasoning as apps/editor.lua's TOP_MARGIN: draw(win, surface) has
-- no wm/theme reference, so this assumes the default theme's title bar
-- height to keep the display and grid out from under it.
local TOP_MARGIN = require("aster.wm").default_theme.title_h + require("aster.wm").default_theme.border

local COL_W, COL_GAP = 44, 4
local ROW_H, ROW_GAP = 30, 6
local GRID_X, GRID_Y = 12, 44
local DISPLAY_X, DISPLAY_Y, DISPLAY_H = 12, 8, 28

-- row/col/label(/span) — a real 4-column, 5-row grid (see header note):
-- row 0 is function keys, rows 1-3 are the digit pad, row 4 is 0/./=.
local BUTTONS = {
  { row = 0, col = 0, label = "C" }, { row = 0, col = 1, label = "+/-" },
  { row = 0, col = 2, label = "%" }, { row = 0, col = 3, label = "/" },
  { row = 1, col = 0, label = "7" }, { row = 1, col = 1, label = "8" },
  { row = 1, col = 2, label = "9" }, { row = 1, col = 3, label = "*" },
  { row = 2, col = 0, label = "4" }, { row = 2, col = 1, label = "5" },
  { row = 2, col = 2, label = "6" }, { row = 2, col = 3, label = "-" },
  { row = 3, col = 0, label = "1" }, { row = 3, col = 1, label = "2" },
  { row = 3, col = 2, label = "3" }, { row = 3, col = 3, label = "+" },
  { row = 4, col = 0, label = "0", span = 2 }, { row = 4, col = 2, label = "." },
  { row = 4, col = 3, label = "=" },
}

local OPS = { ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true }
local FUNCS = { ["+/-"] = true, ["%"] = true }

-- Shared by draw() and click() so a button's clickable area can never
-- drift from what's actually on screen (same reasoning as
-- wm:title_bar_rect/close_button_rect). `b.span` (default 1) widens a
-- button across its own column plus the gaps/columns it swallows — "0"
-- below uses this to span two columns, same width math a 2-column-wide
-- cell would get if the grid just had one fewer column there.
local function button_rect(win, oy, b)
  local span = b.span or 1
  return {
    x = win.x + GRID_X + b.col * (COL_W + COL_GAP),
    y = oy + GRID_Y + b.row * (ROW_H + ROW_GAP),
    w = span * COL_W + (span - 1) * COL_GAP, h = ROW_H,
  }
end

local function button_color(theme, label)
  if label == "C" then return theme.red end
  if label == "=" then return theme.accent end
  if OPS[label] or FUNCS[label] then return theme.surface_alt end
  return theme.surface
end

local function button_text_color(theme, label)
  return label == "=" and theme.background or theme.text
end

-- Truncates (never rounds) to 6 fractional digits and drops a ~0
-- fractional part entirely — a whole-number result reads as "14", not
-- "14.000000". Direct port of calculator.zig's formatFloat.
local function format_number(v)
  if v ~= v or v == math.huge or v == -math.huge then return "error" end
  local sign = v < 0 and "-" or ""
  v = math.abs(v)
  local int_part = math.floor(v)
  local frac = v - int_part
  local out = sign .. tostring(int_part)
  if frac > 1e-9 then
    local digits = ""
    for _ = 1, 6 do
      frac = frac * 10
      local d = math.floor(frac)
      digits = digits .. tostring(d)
      frac = frac - d
      if frac <= 1e-9 then break end
    end
    out = out .. "." .. digits
  end
  return out
end

local function init_state(st)
  st.entry = st.entry or 0
  st.acc = st.acc or 0
  st.op = st.op
  st.fresh = st.fresh == nil and true or st.fresh
  st.has_error = st.has_error or false
  st.has_decimal = st.has_decimal or false
  st.decimal_scale = st.decimal_scale or 0.1
end

local function clear(st)
  st.entry, st.acc, st.op = 0, 0, nil
  st.fresh, st.has_error, st.has_decimal, st.decimal_scale = true, false, false, 0.1
end

local function evaluate(st)
  if st.op == "+" then st.acc = st.acc + st.entry
  elseif st.op == "-" then st.acc = st.acc - st.entry
  elseif st.op == "*" then st.acc = st.acc * st.entry
  elseif st.op == "/" then
    if st.entry == 0 then
      st.has_error, st.op, st.fresh, st.entry = true, nil, true, 0
      return
    end
    st.acc = st.acc / st.entry
  end
  st.op, st.entry, st.fresh = nil, st.acc, true
  st.has_decimal, st.decimal_scale = false, 0.1
end

local function press_digit(st, d)
  if st.fresh then
    st.entry, st.has_decimal, st.decimal_scale, st.fresh = 0, false, 0.1, false
  end
  if st.has_decimal then
    st.entry = st.entry + d * st.decimal_scale
    st.decimal_scale = st.decimal_scale * 0.1
  else
    st.entry = st.entry * 10 + d
  end
end

-- The one button press this whole app funnels through — mouse and
-- keyboard both call this with the same labels the grid draws.
local function press(win, label)
  local st = win.state
  init_state(st)
  if st.has_error and label ~= "C" then clear(st) end
  if label:match("%d") then
    press_digit(st, tonumber(label))
  elseif label == "." then
    if st.fresh then st.entry, st.fresh = 0, false end
    st.has_decimal, st.decimal_scale = true, 0.1
  elseif label == "C" then
    clear(st)
  elseif label == "=" then
    if st.op then evaluate(st) end
  elseif label == "+/-" then
    st.entry = -st.entry
  elseif label == "%" then
    st.entry = st.entry / 100
    st.fresh = true
  elseif OPS[label] then
    if st.op then evaluate(st) else st.acc = st.entry end
    st.op, st.fresh = label, true
  end
end

function M.click(win, x, y)
  local oy = win.y + TOP_MARGIN
  for _, b in ipairs(BUTTONS) do
    local rect = button_rect(win, oy, b)
    if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
      press(win, b.label)
      return
    end
  end
end

-- Backspace/Escape/c both clear, matching calculator.zig's keyToLabel —
-- there's no per-digit backspace in this model, just start over.
function M.key(win, key)
  if key == "enter" then press(win, "=")
  elseif key == "backspace" or key == "escape" or key == "c" then press(win, "C")
  end
end

function M.text(win, str)
  if str:match("^[%d%+%-%*/%.%%]$") then press(win, str) end
end

function M.draw(win, surface)
  local st = win.state
  init_state(st)
  local aster = require("aster")
  local theme = aster.state.wm and aster.state.wm.theme or require("aster.wm").default_theme
  local oy = win.y + TOP_MARGIN

  r.fill_rect(surface, win.x, oy, win.w, win.h - TOP_MARGIN, theme.background)

  local dx, dy, dw, dh = win.x + DISPLAY_X, oy + DISPLAY_Y, win.w - DISPLAY_X * 2, DISPLAY_H
  r.fill_rect(surface, dx, dy, dw, dh, theme.surface)
  local label = st.has_error and "error" or format_number(st.entry)
  local ty = dy + math.floor((dh - r.line_height()) / 2)
  r.text(surface, dx + dw - 8 - r.text_width(label), ty, label, theme.text)
  if not st.has_error and st.op then
    r.text(surface, dx + 6, ty, st.op, theme.text_dim)
  end

  for _, b in ipairs(BUTTONS) do
    local rect = button_rect(win, oy, b)
    r.fill_rect(surface, rect.x, rect.y, rect.w, rect.h, button_color(theme, b.label))
    local tw = r.text_width(b.label)
    r.text(surface, rect.x + math.floor((rect.w - tw) / 2),
      rect.y + math.floor((rect.h - r.line_height()) / 2), b.label, button_text_color(theme, b.label))
  end
end

return M
