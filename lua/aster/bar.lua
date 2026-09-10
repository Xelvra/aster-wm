-- lua/aster/bar.lua — a horizontal strip of widgets along the top of the
-- screen. Same discipline ADR-007 holds apps to: the core never learns a
-- widget's name. A widget is just a table with
-- `draw(bar, surface, x, y, h) -> width` (and optionally `width(bar)` and
-- `click(bar)`), registered from config — see widgets/clock-widget.lua for
-- the shape.

local M = {}
local aster = require("aster")

local Bar = {}
Bar.__index = Bar

function M.new(wm, opts)
  opts = opts or {}
  return setmetatable({
    wm = wm,
    height = opts.height or 28,
    widgets = opts.widgets or {},
    _hit = {},
  }, Bar)
end

-- Left-to-right, left-aligned. A crashing widget is logged and skipped —
-- same principle as wm:guard, just with no window to close over it. Also
-- rebuilds `_hit`, the x-range each widget was just drawn at, so a click
-- (below) can be routed to the same widget without a second layout pass.
function Bar:render(surface)
  local r = require("aster.render")
  local out = aster.state.info.outputs[1]
  r.fill_rect(surface, 0, 0, out.w, self.height, self.wm.theme.surface)
  local x = 8
  self._hit = {}
  for _, widget in ipairs(self.widgets) do
    local ok, w = pcall(widget.draw, self, surface, x, 0, self.height)
    if ok then
      local width = type(w) == "number" and w or 0
      self._hit[#self._hit + 1] = { x0 = x, x1 = x + width, widget = widget }
      x = x + width + 12
    else
      aster.log("bar widget crashed: " .. tostring(w))
    end
  end
end

-- Routes a click at (x, y) to whichever widget was last drawn at that x
-- range, if it declares a `click`. Returns true if a widget handled it, so
-- input.lua knows not to also treat the click as a window-focus click.
-- click(bar, x, widget_x0): x is the click's own absolute position (same
-- coordinate space draw's rects use), widget_x0 is the x the widget was
-- drawn at — a multi-part widget (e.g. workspace-widget's row of
-- capsules) can rebuild its own draw-time layout from that instead of
-- getting only "somewhere inside my whole box" from the bar.
function Bar:click(x, y)
  if y < 0 or y >= self.height then return false end
  for _, hit in ipairs(self._hit) do
    if x >= hit.x0 and x < hit.x1 then
      if hit.widget.click then
        -- Same calling convention as draw(bar, ...): the widget module is
        -- a plain table of functions, not a per-instance object, so only
        -- the bar itself is passed, never a `self`.
        local ok, err = pcall(hit.widget.click, self, x, hit.x0)
        if not ok then aster.log("bar widget click crashed: " .. tostring(err)) end
      end
      return true
    end
  end
  return false
end

return M
