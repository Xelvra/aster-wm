-- lua/aster/init.lua — assembles the aster.* namespace and aster.state.
-- Registered in package.loaded before requiring aster.loop so the two can
-- see each other despite loop.lua's `require("aster")` calls happening at
-- boot()/frame() time, once this table is fully built.

local M = {}
package.loaded["aster"] = M

M.render = require("aster.render")
M.wm = require("aster.wm")
M.input = require("aster.input")

local loop = require("aster.loop")
M.boot = loop.boot
M.frame = loop.frame
M.shutdown = loop.shutdown
M.mark_dirty = loop.mark_dirty

-- The config that ships when ~/.config/aster/wm.lua doesn't exist yet, or
-- can't be recovered from. Never leaves the user at a blank screen.
local function builtin_default()
  local wm = M.wm.adopt {}
  wm.theme = { background = 0x1e2327, accent = 0xff5544, inactive = 0x3b4248, text = 0xd8dee9 }
  local hello = require("apps.hello-window")
  wm:bind("super+q", function() wm:close(M.state.windows[M.state.focus]) end)
  if not next(M.state.windows) then
    wm:open { app = hello, title = "hello" }
  end
  return wm
end

-- Reload protocol (ADR-003): read, compile, snapshot, run in pcall, verify,
-- commit. The "snapshot" is implicit: M.state.config_src is never
-- overwritten until the new source has actually succeeded (the last line
-- of this function), so it's still the old good source for a rollback to
-- read from if `pcall(chunk)` throws.
function M.reload()
  local path = M.info.paths.config .. "/wm.lua"
  local src, err = host.read(path)

  if not src then
    if err == "not_found" then
      builtin_default()
      host.log("aster: no config, using built-in defaults")
    else
      host.log("aster: reload: " .. path .. ": " .. tostring(err))
    end
    M.mark_dirty()
    return
  end

  local chunk, compile_err = load(src, "@wm.lua")
  if not chunk then
    host.log("aster: " .. tostring(compile_err) .. " — keeping previous config")
    if not M.state.wm then builtin_default() end
    M.mark_dirty()
    return
  end

  local ok, result_or_err = pcall(chunk)
  if not ok then
    host.log("aster: wm.lua runtime error: " .. tostring(result_or_err) .. " — rolling back")
    if M.state.config_src then
      pcall(load(M.state.config_src, "@wm.lua"))
    elseif not M.state.wm then
      builtin_default()
    end
    M.mark_dirty()
    return
  end

  M.state.config_src = src
  M.mark_dirty()
end

return M
