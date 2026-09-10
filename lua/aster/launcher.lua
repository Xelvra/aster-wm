-- lua/aster/launcher.lua — Super+Space application launcher: a search box
-- over a filtered list of entries a config registers. Same ADR-007
-- discipline apps and bar widgets already follow — the core never learns
-- the name of anything it might list. Routing: a global keybinding always
-- wins, then the launcher while it's open, then the focused window —
-- lua/aster/input.lua's dispatch() implements that order; this module
-- owns only the launcher's own key/text handling and rendering.

local M = {}
local aster = require("aster")

local Launcher = {}
Launcher.__index = Launcher

function M.new(wm)
  return setmetatable({
    wm = wm,
    entries = {},
    open_flag = false,
    query = "",
    selected = 1,
  }, Launcher)
end

-- launcher:register{title=..., open=fn}: config calls this once per entry.
-- A fresh wm.launcher every adopt() (lua/aster/wm.lua) means old entries
-- are gone on reload (ADR-003), the same way keybindings reset.
function Launcher:register(entry)
  self.entries[#self.entries + 1] = entry
end

function Launcher:is_open()
  return self.open_flag
end

function Launcher:toggle()
  if self.open_flag then self:close() else self:show() end
end

function Launcher:show()
  self.open_flag = true
  self.query = ""
  self.selected = 1
  aster.mark_dirty()
end

function Launcher:close()
  self.open_flag = false
  aster.mark_dirty()
end

-- Case-insensitive substring match on title, in registration order.
function Launcher:filtered()
  local q = self.query:lower()
  local out = {}
  for _, e in ipairs(self.entries) do
    if q == "" or e.title:lower():find(q, 1, true) then
      out[#out + 1] = e
    end
  end
  return out
end

function Launcher:run_selected()
  local item = self:filtered()[self.selected]
  self:close()
  if item and item.open then
    local ok, err = pcall(item.open)
    if not ok then
      aster.log("launcher entry '" .. tostring(item.title) .. "' crashed: " .. tostring(err))
    end
  end
end

-- Called from input.lua's dispatch() while the launcher is open, instead
-- of routing the key to the focused window.
function Launcher:key(key)
  if key == "escape" then
    self:close()
  elseif key == "enter" then
    self:run_selected()
  elseif key == "up" then
    self.selected = math.max(1, self.selected - 1)
    aster.mark_dirty()
  elseif key == "down" then
    local n = math.max(#self:filtered(), 1)
    self.selected = math.min(n, self.selected + 1)
    aster.mark_dirty()
  elseif key == "backspace" then
    self.query = self.query:sub(1, -2)
    self.selected = 1
    aster.mark_dirty()
  end
end

function Launcher:text(str)
  self.query = self.query .. str
  self.selected = 1
  aster.mark_dirty()
end

local ROW_H = 24
local PAD = 12
local MAX_VISIBLE = 8

-- Row rect for filtered-list item `i` — shared by render() and click() so a
-- row's clickable area can never drift from where it's actually drawn (same
-- "one source of truth" reasoning wm:title_bar_rect/close_button_rect use).
local function row_rect(pr, i)
  return { x = pr.x, y = pr.y + PAD + ROW_H * i, w = pr.w, h = ROW_H }
end

-- Called from input.lua's mouse_down while the launcher is open, for a
-- click inside the popup that missed the close "x". Selects and runs
-- whichever row it landed on — a second way in alongside up/down + enter,
-- same as workspace-widget's capsules being a second way into Super+1..9.
function Launcher:click(x, y)
  local pr = self:popup_rect()
  local items = self:filtered()
  for i = 1, math.min(#items, MAX_VISIBLE) do
    local rr = row_rect(pr, i)
    if x >= rr.x and x < rr.x + rr.w and y >= rr.y and y < rr.y + rr.h then
      self.selected = i
      self:run_selected()
      return
    end
  end
end

-- Shared by render() and input.lua's click-outside-closes check, same
-- reason wm:title_bar_rect/close_button_rect are shared with drawing.
function Launcher:popup_rect()
  local out = aster.state.info.outputs[1]
  local items = self:filtered()
  local w = 360
  local h = PAD * 2 + ROW_H + math.min(math.max(#items, 1), MAX_VISIBLE) * ROW_H
  return { x = math.floor((out.w - w) / 2), y = math.floor((out.h - h) / 3), w = w, h = h }
end

-- Close "x" top-right — direct visual port of aster-os's
-- launcher_close_rect: closes the launcher by mouse, so it never forces
-- Escape as the only way out. Shared by render() and input.lua's
-- click-to-close for the same "one source of truth" reason as
-- wm:title_bar_rect.
function Launcher:close_rect()
  local pr = self:popup_rect()
  local size = 20
  return { x = pr.x + pr.w - size - 8, y = pr.y + 4, w = size, h = size }
end

-- A direct visual port of aster-os's launcher_render (run mode): a plain
-- filled popup with a 1px accent border (no rounding — matches the
-- default frame's `theme.radius == 0`), an accent-colored "run: " prompt
-- with white typed text, and the selected row shown in the accent color
-- rather than a highlighted background band.
function Launcher:render(surface)
  if not self.open_flag then return end
  local r = require("aster.render")
  local theme = self.wm.theme
  local pr = self:popup_rect()

  r.fill_rect(surface, pr.x, pr.y, pr.w, pr.h, theme.surface)
  r.rect_border(surface, pr.x, pr.y, pr.w, pr.h, 1, theme.accent)

  local cr = self:close_rect()
  r.text(surface, cr.x + math.floor((cr.w - r.text_width("x")) / 2),
    cr.y + math.floor((cr.h - r.line_height()) / 2), "x", theme.text_dim)

  local prompt = "run: "
  r.text(surface, pr.x + PAD, pr.y + PAD, prompt, theme.accent)
  r.text(surface, pr.x + PAD + r.text_width(prompt), pr.y + PAD, self.query, theme.text)

  local items = self:filtered()
  for i = 1, math.min(#items, MAX_VISIBLE) do
    local item = items[i]
    local rr = row_rect(pr, i)
    local color = (i == self.selected) and theme.accent or theme.text_dim
    r.text(surface, rr.x + PAD, rr.y, item.title, color)
  end
  if #items == 0 then
    local rr = row_rect(pr, 1)
    r.text(surface, rr.x + PAD, rr.y, "no match", theme.text_dim)
  end
end

return M
