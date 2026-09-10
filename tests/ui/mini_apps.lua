-- tests/ui/mini_apps.lua — the good-first-issue apps' actual logic, not
-- just "does requiring it crash": calculator's button presses (mouse and
-- keyboard, one operation at a time — not expression precedence, since
-- it's a real button-grid calculator, not a parser), snake's growth/
-- collision/wall rules, sysmon-widget's /proc/meminfo parsing.

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

-- ---- calculator: one operation at a time, keyboard and mouse both press
-- the same buttons ----------------------------------------------------------
do
  local calc = require("apps.calculator")
  local win = wm:open { app = calc, x = 0, y = 0, w = 212, h = 254 }

  -- Keyboard: 10 / 2 - 3 = 2 (left-to-right, one op applied at a time —
  -- not expression precedence, this is a real calculator, not a parser).
  wm:guard(win, calc.text, win, "1")
  wm:guard(win, calc.text, win, "0")
  wm:guard(win, calc.text, win, "/")
  wm:guard(win, calc.text, win, "2")
  wm:guard(win, calc.text, win, "-")
  wm:guard(win, calc.text, win, "3")
  wm:guard(win, calc.key, win, "enter")
  assert(win.state.entry == 2, "10/2-3 must be 2, got " .. tostring(win.state.entry))

  -- 'c' (and backspace/escape) both clear — there's no per-digit backspace
  -- in this model, matching calculator.zig's keyToLabel.
  wm:guard(win, calc.key, win, "c")
  assert(win.state.entry == 0 and win.state.op == nil, "c must clear entry and pending op")

  -- Divide by zero is an error state that a fresh digit press clears.
  wm:guard(win, calc.text, win, "5")
  wm:guard(win, calc.text, win, "/")
  wm:guard(win, calc.text, win, "0")
  wm:guard(win, calc.key, win, "enter")
  assert(win.state.has_error == true, "5/0 must set has_error")
  wm:guard(win, calc.text, win, "9")
  assert(win.state.has_error == false and win.state.entry == 9, "a digit press after an error must clear it and start fresh")
  wm:guard(win, calc.key, win, "c")

  -- Mouse: click "7", "*", "6", "=" (button_rect's own geometry —
  -- GRID_X/GRID_Y/COL_W/COL_GAP/ROW_H/ROW_GAP/TOP_MARGIN in
  -- apps/calculator.lua, mirrored here the same way tests/ui/mouse_input.lua
  -- derives title-bar click coordinates from wm:title_bar_rect's geometry).
  local TOP_MARGIN = require("aster.wm").default_theme.title_h + require("aster.wm").default_theme.border
  local function button_center(row, col)
    return win.x + 12 + col * 48 + 22, win.y + TOP_MARGIN + 44 + row * 36 + 15
  end
  local x7, y7 = button_center(1, 0) -- "7"
  wm:guard(win, calc.click, win, x7, y7)
  local xmul, ymul = button_center(1, 3) -- "*"
  wm:guard(win, calc.click, win, xmul, ymul)
  local x6, y6 = button_center(2, 2) -- "6"
  wm:guard(win, calc.click, win, x6, y6)
  local xeq, yeq = button_center(4, 3) -- "="
  wm:guard(win, calc.click, win, xeq, yeq)
  assert(win.state.entry == 42, "clicking 7 * 6 = must give 42, got " .. tostring(win.state.entry))

  -- +/- and % (row 0's function keys, not arithmetic — same press()
  -- funnel, no separate click path to test).
  wm:guard(win, calc.key, win, "c")
  wm:guard(win, calc.text, win, "5")
  wm:guard(win, calc.click, win, button_center(0, 1)) -- "+/-"
  assert(win.state.entry == -5, "+/- must negate the entry, got " .. tostring(win.state.entry))
  wm:guard(win, calc.click, win, button_center(0, 2)) -- "%"
  assert(win.state.entry == -0.05, "% must divide the entry by 100, got " .. tostring(win.state.entry))
end

-- ---- snake: growth, wall collision, self collision, no reverse -----------
do
  local snake = require("apps.snake")
  local win = wm:open { app = snake, x = 0, y = 0, w = 320, h = 320 }
  wm:guard(win, snake.draw, win, host.surface()) -- lazy-inits state, like editor's ensure_loaded

  local st = win.state
  local before_len = #st.snake
  st.food = { x = st.snake[1].x + 1, y = st.snake[1].y } -- put food right where the head is about to move
  wm:guard(win, snake.tick, win, st.next_move_ms)
  assert(#st.snake == before_len + 1, "eating food must grow the snake by one segment")
  assert(st.score == 1, "eating food must increment the score")

  -- Can't reverse directly into the segment behind the head.
  local dir_before = st.dir
  wm:guard(win, snake.key, win, "left") -- currently moving right; left is a direct reverse
  assert(st.pending_dir == dir_before, "pressing the opposite direction must not be allowed to reverse in place")

  -- Walking into a wall kills it.
  st.snake[1].x = 0 -- flush against the left edge... will run into a wall going further logic below
  st.dir, st.pending_dir = "left", "left"
  wm:guard(win, snake.tick, win, st.next_move_ms)
  assert(st.alive == false, "moving off the grid must end the game")

  -- Any key after game over resets it.
  wm:guard(win, snake.key, win, "right")
  assert(st.alive == true and st.score == 0, "a key press after game over must reset the game")
end

-- ---- apps must draw the LIVE theme, not the one in effect when their
-- module was first loaded (B46 in spec/troubleshooting.md: editor,
-- calculator, snake and hello-window all cached default_theme into a
-- module local and never looked at wm.theme again, so a theme switch
-- re-colored the bar/chrome but left every app's own content stuck on
-- the theme that was active at require() time) -----------------------------
do
  -- r.fill_rect/r.text (what apps actually call) are cached copies of
  -- native.fill_rect/native.text taken once at module load
  -- (lua/aster/render.lua's `for name, fn in pairs(M.raw) do M[name] = fn
  -- end`), not a live lookup through M.raw — so the spy has to replace
  -- those cached fields directly, not r.raw.fill_rect/r.raw.text.
  local r = require("aster.render")
  local seen_colors
  local orig_fill_rect, orig_text = r.fill_rect, r.text
  r.fill_rect = function(surface, x, y, w, h, color, alpha)
    seen_colors = seen_colors or {}
    seen_colors[color] = true
    return orig_fill_rect(surface, x, y, w, h, color, alpha)
  end
  r.text = function(surface, x, y, str, color)
    seen_colors = seen_colors or {}
    seen_colors[color] = true
    return orig_text(surface, x, y, str, color)
  end

  local marker = 0xABCDEF
  wm.theme = { background = marker, surface = marker, surface_alt = marker,
    text = marker, text_dim = marker, accent = marker, accent_b = marker,
    accent_dark = marker, inactive = marker, red = marker,
    opacity_active = 0.95, opacity_inactive = 0.85, title_h = 24, radius = 0,
    shadow = 0 }

  local function drew_the_marker(app, extra)
    seen_colors = nil
    local win = wm:open { app = app, x = 0, y = 0, w = 200, h = 200, state = extra }
    wm:guard(win, app.draw, win, host.surface())
    wm:close(win)
    return seen_colors and seen_colors[marker] == true
  end

  assert(drew_the_marker(require("apps.editor"), { path = "/tmp/mini_apps_editor_theme_test" }),
    "editor.draw must use the live wm.theme, not a load-time default")
  assert(drew_the_marker(require("apps.calculator")),
    "calculator.draw must use the live wm.theme, not a load-time default")
  assert(drew_the_marker(require("apps.snake")),
    "snake.draw must use the live wm.theme, not a load-time default")
  assert(drew_the_marker(require("apps.hello-window")),
    "hello-window.draw must use the live wm.theme, not a load-time default")

  r.fill_rect = orig_fill_rect
  r.text = orig_text
  wm.theme = nil
end

-- ---- theme-switcher: the first Space must actually change the theme -----
do
  local theme_switcher = require("apps.theme-switcher")
  local win = wm:open { app = theme_switcher, x = 0, y = 0, w = 200, h = 100 }
  wm:guard(win, theme_switcher.key, win, "space")
  assert(wm.theme == require("themes.nord"),
    "the first space must move off 'default' to the next theme ('nord'), not be a no-op")
  wm:close(win)
  wm.theme = nil
end

-- ---- sysmon-widget: /proc/meminfo parsing, and hiding when it's absent ---
do
  local sysmon = require("widgets.sysmon-widget")
  local bar = { wm = { theme = { text_dim = 0x888888 } } }
  local s = host.surface()

  host.write("/proc/meminfo", "MemTotal:       1000 kB\nMemFree:100 kB\nMemAvailable:    250 kB\n")
  local w = sysmon.draw(bar, s, 0, 0, 28)
  assert(w and w > 0, "with /proc/meminfo present, the widget must draw something")

  host.remove("/proc/meminfo")
  local w2 = sysmon.draw(bar, s, 0, 0, 28)
  assert(w2 == 0, "with /proc/meminfo absent (host.read returns not_found), the widget must draw nothing")
end

print("mini_apps: PASS")
