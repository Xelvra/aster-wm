-- widgets/sysmon-widget.lua — a bar widget showing memory usage from
-- /proc/meminfo. host.read on a path that doesn't exist on this backend
-- (wasm, a future non-Linux backend, ...) returns `nil, "not_found"`
-- rather than failing outright — the widget just draws nothing and
-- returns 0 width, the same graceful-degradation shape
-- widgets/clock-widget.lua demonstrates for host.clock()'s caps.

local M = {}

local function parse_kb(content, key)
  local line = content:match(key .. ":%s*(%d+)")
  return line and tonumber(line)
end

function M.draw(bar, surface, x, y, h)
  local content = host.read("/proc/meminfo")
  if not content then return 0 end

  local total = parse_kb(content, "MemTotal")
  local avail = parse_kb(content, "MemAvailable")
  if not total or not avail or total == 0 then return 0 end

  local used_pct = math.floor((total - avail) * 100 / total)
  local r = require("aster.render")
  local text = "mem " .. used_pct .. "%"
  local ty = y + math.floor((h - r.line_height()) / 2)
  r.text(surface, x, ty, text, bar.wm.theme.text_dim)
  return r.text_width(text)
end

return M
