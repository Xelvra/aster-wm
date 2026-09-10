-- lua/aster/loop.lua — the only place that talks to host.wait and host.present.

local M = {}
local aster = require("aster")

local dirty = true
local last_cfg_ms = 0
local CFG_POLL_MS = 1000

function M.mark_dirty() dirty = true end

-- wm.lua's current mtime, or nil if it doesn't exist. Shared by boot() (to
-- prime the baseline) and frame() (to poll it) — see B9.
local function config_mtime()
  local entries = host.list(aster.state.info.paths.config)
  if not entries then return nil end
  for _, e in ipairs(entries) do
    if e.name == "wm.lua" then return e.mtime end
  end
  return nil
end

-- ADR-015: a fresh install (native, or the wasm demo's localStorage) has
-- no ~/.config/aster/wm.lua yet, so before the very first reload(), write
-- the embedded default there — once, here, not inside reload() itself, so
-- it never fights ADR-003's rollback protocol or the reload_* tests, and
-- never re-seeds a file the user deliberately deleted (M.boot() only ever
-- runs once, at process start). __aster_default_config is pushed once by
-- src/host/lua.zig (modules.zig's pushDefaultConfig) — not a host.*
-- function (P2 stays twelve), the same kind of second infrastructure
-- global __native_render already is.
local function seed_config_if_missing(path)
  local existing, err = host.read(path)
  if existing or err ~= "not_found" then return end
  local ok, werr = host.write(path, __aster_default_config)
  if ok then
    aster.log("seeded default config at " .. path)
  else
    aster.log("could not seed default config at " .. path .. ": " .. tostring(werr))
  end
end

function M.boot()
  aster.state = aster.state or {
    windows = {}, next_id = 1, next_z = 1, workspaces = {}, current_ws = 1, focus = nil,
    wm = nil, config_src = nil, info = nil, last_mtime = nil,
  }
  aster.state.info = host.info()
  seed_config_if_missing(aster.state.info.paths.config .. "/wm.lua")
  aster.reload() -- loads config/wm.lua; falls back to the built-in default
  aster.state.last_mtime = config_mtime()
end

function M.frame()
  while true do
    local e = host.wait(0)
    if not e then break end
    if e.type == "quit" then return "quit" end
    if e.type == "resize" then
      aster.state.info = host.info()
      M.mark_dirty() -- see B18 in spec/troubleshooting.md
    end
    aster.input.dispatch(e)
  end

  local now = host.now_ms()
  if aster.state.wm then aster.state.wm:tick(now) end

  if now - last_cfg_ms > CFG_POLL_MS then
    last_cfg_ms = now
    -- External-edit watch (spec/architecture.md "Reload preserves state").
    local mtime = config_mtime()
    if mtime ~= aster.state.last_mtime then
      aster.state.last_mtime = mtime
      if mtime then aster.reload() end
    end
  end

  if not dirty then return "idle" end
  if aster.state.wm then aster.state.wm:render(host.surface()) end
  host.present()
  dirty = false
  return "running"
end

function M.shutdown()
  -- persist nothing by design: the config file is the state that matters
end

return M
