-- tests/ui/editor.lua — apps/editor.lua: whole-file IO (no file handles),
-- state in win.state (not globals, so two instances stay independent),
-- basic editing (insert, backspace, delete, enter, arrows), Ctrl+S saves,
-- and UTF-8-aware cursor movement (a multi-byte codepoint moves/deletes as
-- one unit, never splits mid-sequence).

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
local editor = require("apps.editor")

host.write("/doc.txt", "hello\nworld")
local win = wm:open { app = editor, state = { path = "/doc.txt" } }

-- Loading happens lazily, on first draw/key/text call, not at open() time.
assert(win.state.lines == nil, "editor must not read the file until first used")
wm:guard(win, editor.key, win, "right", {})
assert(#win.state.lines == 2 and win.state.lines[1] == "hello" and win.state.lines[2] == "world",
  "the file must be split into lines on first use")

-- Typing inserts at the cursor.
win.state.row, win.state.col = 1, 6 -- end of "hello"
wm:guard(win, editor.text, win, "!")
assert(win.state.lines[1] == "hello!", "text must insert at the cursor")
assert(win.state.col == 7, "the cursor must advance past what was just inserted")
assert(win.state.dirty, "typing must mark the buffer dirty")

-- Enter splits the current line.
wm:guard(win, editor.key, win, "enter", {})
assert(win.state.lines[1] == "hello!" and win.state.lines[2] == "" and win.state.lines[3] == "world",
  "enter must split the line at the cursor and insert a new line")
assert(win.state.row == 2 and win.state.col == 1, "enter must move the cursor to the start of the new line")

-- Backspace at the start of a line merges it into the previous one.
wm:guard(win, editor.key, win, "backspace", {})
assert(win.state.lines[1] == "hello!" and win.state.lines[2] == "world" and #win.state.lines == 2,
  "backspace at column 1 must merge with the previous line")
assert(win.state.row == 1 and win.state.col == 7, "backspace-merge must place the cursor at the join point")

-- Delete at the end of a line merges the next one in.
win.state.row, win.state.col = 1, 7 -- end of "hello!"
wm:guard(win, editor.key, win, "delete", {})
assert(win.state.lines[1] == "hello!world" and #win.state.lines == 1,
  "delete at the end of a line must merge the next line in")

-- Ctrl+S writes the whole buffer back in one host.write, and clears dirty.
wm:guard(win, editor.key, win, "s", { ctrl = true })
local saved = host.read("/doc.txt")
assert(saved == "hello!world", "ctrl+s must write the buffer back, got: " .. tostring(saved))
assert(not win.state.dirty, "a successful save must clear dirty")

-- UTF-8: a multi-byte codepoint moves and deletes as one unit.
win.state.lines = { "a\xc3\xa9z" } -- "a", U+00E9 (é, 2 bytes), "z"
win.state.row, win.state.col = 1, 1
wm:guard(win, editor.key, win, "right", {}) -- past "a"
assert(win.state.col == 2, "moving right past an ASCII byte advances by 1")
wm:guard(win, editor.key, win, "right", {}) -- past "é" (2 bytes)
assert(win.state.col == 4, "moving right past a 2-byte codepoint must advance by 2, not split it")
wm:guard(win, editor.key, win, "backspace", {})
assert(win.state.lines[1] == "az", "backspace must delete the whole 2-byte codepoint, not one byte of it")

-- Horizontal scroll only ever moves the CURSOR's own line — a long
-- current line scrolled into view must never shift any other line
-- sideways too (that line has nothing to do with where the cursor is).
do
  local r = require("aster.render")
  local win3 = wm:open { app = editor, state = { path = "/scroll.txt" }, x = 0, y = 0, w = 100, h = 200 }
  win3.state.lines = { "short", string.rep("x", 60), "short2" }
  win3.state.row, win3.state.col = 2, 61 -- end of the long line
  win3.state.scroll_row, win3.state.scroll_col = 1, 1
  win3.state.dirty = false

  local drawn = {}
  local real_text = r.text
  r.text = function(surface, x, y, text, color)
    drawn[#drawn + 1] = text
    return real_text(surface, x, y, text, color)
  end
  local ok, err = pcall(editor.draw, win3, host.surface())
  r.text = real_text
  assert(ok, "draw must not crash: " .. tostring(err))

  assert(drawn[1] == "short", "a line above the cursor's line must render unscrolled, got: " .. tostring(drawn[1]))
  assert(drawn[2] ~= string.rep("x", 60), "the cursor's own long line must actually be scrolled")
  assert(drawn[3] == "short2", "a line below the cursor's line must render unscrolled, got: " .. tostring(drawn[3]))
end

-- The editor must paint its own opaque background before drawing text on
-- top of it — every other app does (apps/calculator.lua, apps/snake.lua),
-- this one didn't, so whatever was drawn earlier at those pixels (a
-- window underneath, if one happens to be there) showed straight through.
do
  local r = require("aster.render")
  local win4 = wm:open { app = editor, state = { path = "/bg.txt" }, x = 0, y = 0, w = 200, h = 150 }
  win4.state.lines = { "x" }
  win4.state.row, win4.state.col = 1, 1
  win4.state.scroll_row, win4.state.scroll_col = 1, 1

  local filled_window = false
  local real_fill_rect = r.fill_rect
  r.fill_rect = function(surface, x, y, w, h, color, alpha)
    if x == win4.x and w == win4.w and h >= win4.h - 40 then filled_window = true end
    return real_fill_rect(surface, x, y, w, h, color, alpha)
  end
  local ok, err = pcall(editor.draw, win4, host.surface())
  r.fill_rect = real_fill_rect
  assert(ok, "draw must not crash: " .. tostring(err))
  assert(filled_window, "editor.draw must fill its own window-sized background before drawing text")
end

-- Two independent instances of the same app never share state (win.state,
-- not globals — spec/architecture.md's per-window state contract).
host.write("/other.txt", "second file")
local win2 = wm:open { app = editor, state = { path = "/other.txt" } }
wm:guard(win2, editor.key, win2, "right", {})
assert(win.state.lines[1] == "az", "editing one window's buffer must not affect another instance's state")
assert(win2.state.path == "/other.txt" and win.state.path == "/doc.txt",
  "each instance must keep its own path")

print("editor: PASS")
