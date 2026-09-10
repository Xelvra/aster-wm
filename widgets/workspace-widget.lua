-- widgets/workspace-widget.lua — a bar widget (aster.bar.new's widget
-- contract) drawing a capsule per workspace plus a "+" to add another, a
-- direct visual port of aster-os's own ws_capsules/bar_render capsule look
-- (the current workspace's capsule filled with the accent color and a
-- background-colored label, the rest surface_alt/text_dim). aster-os drew
-- a fixed, named list (theme.ws); aster-wm's workspaces are just numbers
-- with no fixed count, so this shows only as many as are actually in use
-- (wm:workspace_count(), lua/aster/wm.lua — at least 2), plus a "+"
-- capsule that creates and switches to a new empty one
-- (wm:add_workspace()). Switching an existing one is still Super+1..9
-- (config/wm.lua) — clicking a capsule is just a second way in.

local aster = require("aster")

local M = {}

-- Shared by draw() and click() so a capsule's clickable area can never
-- drift from what's actually on screen — same "one source of truth"
-- reasoning wm:title_bar_rect/close_button_rect already use. `x` is the
-- absolute screen x the widget starts at (what Bar:render/click both pass
-- as the widget's own offset).
local function layout(wm, r, x, h)
  local size = math.min(20, h - 4)
  local cx = x
  local caps = {}
  for i = 1, wm:workspace_count() do
    local label = tostring(i)
    local w = math.max(size, r.text_width(label) + 8)
    caps[#caps + 1] = { x0 = cx, x1 = cx + w, w = w, label = label, ws = i }
    cx = cx + w + 6
  end
  caps[#caps + 1] = { x0 = cx, x1 = cx + size, w = size, label = "+", ws = nil }
  cx = cx + size
  return caps, size, cx - x
end

function M.draw(bar, surface, x, y, h)
  local r = require("aster.render")
  local theme = bar.wm.theme
  local current = aster.state.current_ws or 1
  local caps, size, total_w = layout(bar.wm, r, x, h)
  local cy = y + math.floor((h - size) / 2)
  for _, cap in ipairs(caps) do
    local active = cap.ws == current
    local bg = active and theme.accent or theme.surface_alt
    local fg = active and theme.background or theme.text_dim
    r.fill_rect(surface, cap.x0, cy, cap.w, size, bg)
    r.text(surface, cap.x0 + math.floor((cap.w - r.text_width(cap.label)) / 2),
      cy + math.floor((size - r.line_height()) / 2), cap.label, fg)
  end
  return total_w
end

function M.click(bar, x, x0)
  local r = require("aster.render")
  local caps = layout(bar.wm, r, x0, bar.height)
  for _, cap in ipairs(caps) do
    if x >= cap.x0 and x < cap.x1 then
      if cap.ws then
        bar.wm:goto_workspace(cap.ws)
      else
        bar.wm:add_workspace()
      end
      return
    end
  end
end

return M
