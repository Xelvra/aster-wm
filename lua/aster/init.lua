-- lua/aster/init.lua — assembles the aster.* namespace and aster.state.
-- Registered in package.loaded before requiring aster.loop so the two can
-- see each other despite loop.lua's `require("aster")` calls happening at
-- boot()/frame() time, once this table is fully built.

local M = {}
package.loaded["aster"] = M

M.render = require("aster.render")
M.wm = require("aster.wm")
M.input = require("aster.input")
M.bar = require("aster.bar")
M.launcher = require("aster.launcher")

local loop = require("aster.loop")
M.boot = loop.boot
M.frame = loop.frame
M.shutdown = loop.shutdown
M.mark_dirty = loop.mark_dirty

-- Every log line the core emits is prefixed the same way; shared so it's
-- spelled once instead of at each of the dozen call sites across the core.
function M.log(msg)
  host.log("aster: " .. msg)
end

-- The core's own bootstrap screen, drawn with the render primitives
-- directly rather than pulled in from apps/ — ADR-007 forbids the core
-- referencing any app by name, including the ones shipped in this repo.
local function fallback_screen(theme)
  return {
    draw = function(win, surface)
      M.render.fill_rect(surface, win.x, win.y, win.w, win.h, theme.background)
      M.render.text(surface, win.x + 12, win.y + 12,
        "no ~/.config/aster/wm.lua found", theme.text)
      M.render.text(surface, win.x + 12, win.y + 12 + M.render.line_height(),
        "running built-in defaults — super+q closes this window", theme.inactive)
    end,
  }
end

-- The config that ships when ~/.config/aster/wm.lua doesn't exist yet, or
-- can't be recovered from. Never leaves the user at a blank screen.
-- No explicit `wm.theme` here: adopt({}) already resets it to
-- aster.wm.default_theme (D4), the same colors this used to spell out
-- literally.
local function builtin_default()
  local wm = M.wm.adopt {}
  wm:bind("super+q", function() wm:close(M.state.windows[M.state.focus]) end)
  if not next(M.state.windows) then
    wm:open { app = fallback_screen(wm.theme), title = "aster" }
  end
  return wm
end

-- The error bubble (ADR-003, spec/architecture.md "Reload preserves
-- state"): drawn from Lua by wm.lua's render(), never by Zig (rule 4).
-- Cleared by the next successful reload or by Escape (aster.input).
function M.set_error(line1, line2)
  M.state.error_bubble = { line1 = line1, line2 = line2 }
end

function M.clear_error()
  M.state.error_bubble = nil
end

-- Re-runs the last known-good source (ADR-003's reload protocol: rollback).
-- Returns true only if that source both ran clean AND returned the
-- adopted wm — the same bar a fresh reload has to clear.
local function try_rollback()
  if not M.state.config_src then return false end
  local ok, result = pcall(load(M.state.config_src, "@wm.lua"))
  return ok and result == M.state.wm
end

-- Reload protocol (ADR-003): read, compile, snapshot, run in pcall, verify,
-- commit. The "snapshot" is implicit: M.state.config_src is never
-- overwritten until the new source has actually succeeded (the last line
-- of this function), so it's still the old good source for a rollback to
-- read from if `pcall(chunk)` throws or the result fails verification.
function M.reload()
  M.input.reset_parse_cache()
  local path = M.state.info.paths.config .. "/wm.lua"
  local src, err = host.read(path)

  if not src then
    if err == "not_found" then
      M.clear_error()
      if not M.state.wm then builtin_default() end
      M.log("no config, using built-in defaults")
    else
      -- Anything other than "not_found" (permission, io, busy, invalid — see
      -- B14) must be treated exactly like a compile/runtime error: on first
      -- boot M.state.wm is still nil, and loop.lua's M:render() is not
      -- guarded against that the way M:tick() is.
      M.log("reload: " .. path .. ": " .. tostring(err))
      if M.state.wm then
        M.set_error("wm.lua: " .. tostring(err), "keeping previous config — desktop untouched")
      else
        builtin_default()
        M.set_error("wm.lua: " .. tostring(err) .. " — running built-in defaults")
      end
    end
    M.mark_dirty()
    return
  end

  local chunk, compile_err = load(src, "@wm.lua")
  if not chunk then
    M.log(tostring(compile_err) .. " — keeping previous config")
    M.set_error(tostring(compile_err), "keeping previous config — desktop untouched")
    if not M.state.wm then builtin_default() end
    M.mark_dirty()
    return
  end

  -- Step 5, "verify": a config that never calls aster.wm.adopt() (or
  -- returns something else) hasn't actually reset itself into the
  -- singleton — treat it exactly like a runtime error, below. See B16 in
  -- spec/troubleshooting.md for why `result == nil` must be checked
  -- separately from `result ~= M.state.wm`.
  local ok, result = pcall(chunk)
  if ok and (result == nil or result ~= M.state.wm) then
    ok = false
    result = "wm.lua must call aster.wm.adopt() and return its result"
  end

  if not ok then
    M.log("wm.lua error: " .. tostring(result) .. " — rolling back")
    if try_rollback() then
      M.set_error(tostring(result), "keeping previous config — desktop untouched")
    else
      -- Unconditional — see B10.
      builtin_default()
      M.set_error("config rollback failed, running built-in defaults")
    end
    M.mark_dirty()
    return
  end

  M.state.config_src = src
  M.clear_error()
  M.mark_dirty()
end

return M
