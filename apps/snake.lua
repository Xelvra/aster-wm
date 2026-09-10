-- apps/snake.lua — a small interactive game: real per-window state
-- (win.state) and real timing (win.state.next_move_ms against
-- host.now_ms()), unlike plasma.lua's stateless per-frame effect.

local r = require("aster.render")

local M = {}
M.name = "snake"

-- Same reasoning as apps/editor.lua's TOP_MARGIN: draw(win, surface) has
-- no wm/theme reference, so this assumes the default theme's title bar
-- height to keep the grid's top row out from under it.
local TOP_MARGIN = require("aster.wm").default_theme.title_h + require("aster.wm").default_theme.border
local CELL = 16
local MOVE_MS = 150 -- constant regardless of length — making this shrink as the snake grows is a good first issue, not done yet

local DIRS = {
  up = { x = 0, y = -1 },
  down = { x = 0, y = 1 },
  left = { x = -1, y = 0 },
  right = { x = 1, y = 0 },
}

local function grid_size(win)
  return math.max(4, win.w // CELL), math.max(4, (win.h - TOP_MARGIN) // CELL)
end

local function reset(win)
  local cols, rows = grid_size(win)
  local st = win.state
  st.snake = { { x = math.floor(cols / 2), y = math.floor(rows / 2) } }
  st.dir = "right"
  st.pending_dir = "right"
  st.food = { x = math.random(0, cols - 1), y = math.random(0, rows - 1) }
  st.score = 0
  st.alive = true
  st.next_move_ms = host.now_ms() + MOVE_MS
end

local function occupies(snake, x, y)
  for _, seg in ipairs(snake) do
    if seg.x == x and seg.y == y then return true end
  end
  return false
end

local function place_food(win)
  local cols, rows = grid_size(win)
  local st = win.state
  repeat
    st.food = { x = math.random(0, cols - 1), y = math.random(0, rows - 1) }
  until not occupies(st.snake, st.food.x, st.food.y)
end

function M.key(win, key)
  local st = win.state
  if not st.snake then reset(win); return end
  if not st.alive then
    reset(win)
    return
  end
  local d = DIRS[key]
  if not d then return end
  -- Can't reverse directly into the segment behind the head.
  local cur = DIRS[st.dir]
  if d.x == -cur.x and d.y == -cur.y then return end
  st.pending_dir = key
end

function M.tick(win, now_ms)
  local st = win.state
  if not st.snake then reset(win) end
  if not st.alive then return false end
  if now_ms < st.next_move_ms then return false end
  st.next_move_ms = now_ms + MOVE_MS
  st.dir = st.pending_dir

  local cols, rows = grid_size(win)
  local d = DIRS[st.dir]
  local head = st.snake[1]
  local nx, ny = head.x + d.x, head.y + d.y

  if nx < 0 or ny < 0 or nx >= cols or ny >= rows or occupies(st.snake, nx, ny) then
    st.alive = false
    return true
  end

  table.insert(st.snake, 1, { x = nx, y = ny })
  if nx == st.food.x and ny == st.food.y then
    st.score = st.score + 1
    place_food(win)
  else
    table.remove(st.snake) -- didn't grow: drop the tail
  end
  return true
end

function M.draw(win, surface)
  local aster = require("aster")
  local theme = aster.state.wm and aster.state.wm.theme or require("aster.wm").default_theme
  local st = win.state
  if not st.snake then reset(win) end
  local oy = win.y + TOP_MARGIN

  r.fill_rect(surface, win.x, oy, win.w, win.h - TOP_MARGIN, theme.background)

  for i, seg in ipairs(st.snake) do
    local color = i == 1 and theme.accent or theme.accent_b
    r.fill_rect(surface, win.x + seg.x * CELL, oy + seg.y * CELL, CELL - 1, CELL - 1, color)
  end
  r.fill_rect(surface, win.x + st.food.x * CELL, oy + st.food.y * CELL, CELL - 1, CELL - 1, theme.red)

  -- Score is drawn in the body, not the title bar — moving it there is a
  -- good first issue, not something already done.
  r.text(surface, win.x + 6, win.y + win.h - r.line_height() - 4, "score: " .. st.score, theme.text)
  if not st.alive then
    r.text(surface, win.x + 6, oy + 4, "game over — press any key", theme.red)
  end
end

return M
