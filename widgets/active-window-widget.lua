-- widgets/active-window-widget.lua — a bar widget (aster.bar.new's widget
-- contract) showing the focused window's title, a direct port of
-- aster-os's own bar_render "Active window title (bar center, the
-- Noctalia active_window widget)". aster-os centers it on the whole
-- screen, not wherever the bar's left-to-right flow happened to place it
-- — Bar:render still calls draw(bar, surface, x, y, h) in slot order, but
-- this widget ignores its slot's x and recomputes the true screen center
-- from aster.state.info, then returns 0 so it takes no width of its own
-- in that flow (there's nothing after it to push aside).
--
-- aster-os never had this collision: its workspace list was a fixed,
-- short, named set (theme.ws). aster-wm's workspace-widget grows a
-- capsule per workspace with no upper bound (config/wm.lua's "+" —
-- widgets/workspace-widget.lua), so a screen with enough workspaces added
-- can genuinely reach center screen. Rather than truncate or shove the
-- title sideways (both would make it collide with something else, or
-- stop reading as "centered"), this widget hides itself once whatever
-- was drawn before it (launcher/clock/workspaces — Bar:render's own `x`
-- cursor, the running left edge of "everything so far") would already
-- reach into its own centered span. A title that's about to collide
-- disappears cleanly instead of getting torn in half by the next capsule.

local aster = require("aster")

local M = {}

function M.draw(bar, surface, x, y, h)
  local r = require("aster.render")
  local win = aster.state.windows[aster.state.focus]
  local label = win and win.title or ""
  if label == "" then return 0 end
  local out = aster.state.info.outputs[1]
  local tx = math.floor((out.w - r.text_width(label)) / 2)
  local margin = 8
  if tx - margin < x then return 0 end
  local ty = y + math.floor((h - r.line_height()) / 2)
  r.text(surface, tx, ty, label, bar.wm.theme.text_dim)
  return 0
end

return M
