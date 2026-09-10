-- widgets/clock-widget.lua — a bar widget (aster.bar.new's widget contract:
-- draw(bar, surface, x, y, h) -> width), not a window app. Demonstrates
-- host-contract.md's caps story: host.clock() gives wall-clock time when
-- the backend has one; a backend without a real-time clock returns
-- `nil, "unsupported"` (and reports caps.clock == false) instead of
-- failing outright, so this switches to uptime — the same code path
-- either way, not two separate widgets, since the whole point of caps is
-- that a widget degrades gracefully instead of assuming everyone has it.

local M = {}

local function format_uptime(now_ms)
  local secs = math.floor(now_ms / 1000)
  local hh = math.floor(secs / 3600)
  local mm = math.floor(secs / 60) % 60
  local ss = secs % 60
  return string.format("up %02d:%02d:%02d", hh, mm, ss)
end

local function format_clock(clock)
  local local_secs = math.floor(clock.unix_ms / 1000) + clock.utc_offset_min * 60
  local secs = local_secs % 86400
  local hh = math.floor(secs / 3600)
  local mm = math.floor(secs / 60) % 60
  return string.format("%02d:%02d", hh, mm)
end

function M.draw(bar, surface, x, y, h)
  local r = require("aster.render")
  local clock = host.clock()
  local text = clock and format_clock(clock) or format_uptime(host.now_ms())
  local ty = y + math.floor((h - r.line_height()) / 2)
  r.text(surface, x, ty, text, bar.wm.theme.text)
  return r.text_width(text)
end

return M
