-- lua/aster/loop.lua — the only place that talks to host.wait and host.present.

local M = {}

local dirty = true
local last_cfg_ms = 0
local CFG_POLL_MS = 1000

function M.mark_dirty() dirty = true end

function M.boot()
  local aster = require("aster")
  aster.state = aster.state or {
    windows = {}, next_id = 1, next_z = 1, workspaces = {}, focus = nil,
    wm = nil, config_src = nil,
  }
  aster.info = host.info()
  aster.reload() -- loads config/wm.lua; falls back to the built-in default
end

function M.frame()
  local aster = require("aster")

  while true do
    local e = host.wait(0)
    if not e then break end
    if e.type == "quit" then return "quit" end
    if e.type == "resize" then aster.info = host.info() end
    aster.input.dispatch(e)
  end

  local now = host.now_ms()
  if aster.state.wm then aster.state.wm:tick(now) end

  if now - last_cfg_ms > CFG_POLL_MS then
    last_cfg_ms = now
    -- external-edit watch: reload wm.lua when its mtime moves forward
    local path = aster.info.paths.config
    local entries = host.list(path)
    if entries then
      for _, e in ipairs(entries) do
        if e.name == "wm.lua" then
          aster.last_mtime = aster.last_mtime or e.mtime
          if e.mtime > aster.last_mtime then
            aster.last_mtime = e.mtime
            aster.reload()
          end
        end
      end
    end
  end

  if not dirty then return "idle" end
  aster.state.wm:render(host.surface())
  host.present()
  dirty = false
  return "running"
end

function M.shutdown()
  -- persist nothing by design: the config file is the state that matters
end

return M
