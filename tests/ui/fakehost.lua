-- tests/ui/fakehost.lua — a reference implementation of the host contract
-- (spec/host-contract.md), for running lua/aster/*.lua and apps/*.lua under
-- a plain host Lua 5.4 interpreter, no graphics, no real backend. Load this
-- before requiring "aster" — it sets the `host` and `__native_render`
-- globals every module in this repo assumes exist.
--
-- Doubles as executable documentation of the contract: if you don't know
-- what `host.rename` is supposed to do, the five lines below are the answer.

local M = {}

-- ---- in-memory "filesystem" ------------------------------------------

local fs = {} -- path -> { data = string, mtime = number }
local mtime_clock = 0

local function next_mtime()
  mtime_clock = mtime_clock + 1
  return mtime_clock
end

local function is_dir(path)
  local prefix = path == "" and "" or (path .. "/")
  for p in pairs(fs) do
    if p:sub(1, #prefix) == prefix then return true end
  end
  return false
end

-- ---- event queue --------------------------------------------------------

local events = {}

local function push(ev) events[#events + 1] = ev end

-- The real SDL backend always sends all four modifier keys as booleans
-- (spec/host-contract.md); fill in whatever a caller omitted the same way,
-- so tests exercise the event shape production code actually sees.
local function full_mods(mods)
  mods = mods or {}
  return {
    ctrl = mods.ctrl or false,
    alt = mods.alt or false,
    shift = mods.shift or false,
    super = mods.super or false,
  }
end

function M._push_key(key, mods) push({ type = "key_down", key = key, mods = full_mods(mods) }) end
function M._push_key_up(key, mods) push({ type = "key_up", key = key, mods = full_mods(mods) }) end
function M._push_text(str) push({ type = "text", text = str }) end
function M._push_mouse_move(x, y, dx, dy) push({ type = "mouse_move", x = x, y = y, dx = dx or 0, dy = dy or 0 }) end
function M._push_mouse_down(x, y, button) push({ type = "mouse_down", x = x, y = y, button = button or "left" }) end
function M._push_mouse_up(x, y, button) push({ type = "mouse_up", x = x, y = y, button = button or "left" }) end
function M._push_scroll(x, y, dx, dy) push({ type = "scroll", x = x, y = y, dx = dx or 0, dy = dy or 0 }) end
function M._push_resize(w, h) push({ type = "resize", w = w, h = h }) end
function M._push_focus(focused) push({ type = "focus", focused = focused }) end
function M._push_quit() push({ type = "quit" }) end

-- ---- host.* ---------------------------------------------------------

local now_ms = 0
function M._set_now_ms(ms) now_ms = ms end
function M._advance_ms(ms) now_ms = now_ms + ms end

local clock_value = { unix_ms = 0, utc_offset_min = 0 }
function M._set_clock(unix_ms, utc_offset_min)
  clock_value = { unix_ms = unix_ms, utc_offset_min = utc_offset_min or 0 }
end

local info = {
  backend = "fakehost",
  format = "xrgb8888",
  pitch = 1920 * 4,
  outputs = { { id = 1, x = 0, y = 0, w = 1920, h = 1080, scale = 1.0, primary = true } },
  paths = { config = "/fake/config", data = "/fake/data", home = "/fake/home" },
  caps = { clock = true, spawn = false, damage = false, inject = false },
}
function M._set_info(overrides)
  for k, v in pairs(overrides) do info[k] = v end
end

M.log_lines = {}

_G.host = {
  info = function() return info end,
  surface = function() return {} end, -- opaque; tests/ui/ never draws pixels
  present = function() end,
  wait = function(_timeout_ms)
    return table.remove(events, 1)
  end,
  now_ms = function() return now_ms end,
  clock = function()
    if not info.caps.clock then return nil, "unsupported" end
    return clock_value
  end,
  read = function(path)
    local entry = fs[path]
    if not entry then return nil, "not_found" end
    return entry.data
  end,
  write = function(path, data)
    fs[path] = { data = data, mtime = next_mtime() }
    return true
  end,
  list = function(path)
    if not is_dir(path) and path ~= "" then return nil, "not_found" end
    local prefix = path == "" and "" or (path .. "/")
    local seen, out = {}, {}
    for p, entry in pairs(fs) do
      if p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        local name = rest:match("^[^/]+")
        if name and not seen[name] then
          seen[name] = true
          local is_subdir = rest ~= name
          out[#out + 1] = {
            name = name,
            dir = is_subdir,
            size = is_subdir and 0 or #entry.data,
            mtime = entry.mtime,
          }
        end
      end
    end
    return out
  end,
  remove = function(path)
    if not fs[path] and not is_dir(path) then return nil, "not_found" end
    local prefix = path .. "/"
    fs[path] = nil
    for p in pairs(fs) do
      if p:sub(1, #prefix) == prefix then fs[p] = nil end
    end
    return true
  end,
  rename = function(from, to)
    if not fs[from] then return nil, "not_found" end
    if fs[to] then return nil, "exists" end
    fs[to] = fs[from]
    fs[from] = nil
    return true
  end,
  log = function(str)
    M.log_lines[#M.log_lines + 1] = str
  end,
}

-- ---- __native_render -----------------------------------------------
--
-- As a reference implementation, this must be at least as strict as the
-- real renderer's luaL_check* argument checks (src/host/bindings.zig), or
-- a typo that passes nil/a wrong type here would sail through tests/ui/
-- and only blow up against the real backend. Drawing itself stays a no-op
-- — tests/ui/ never checks pixels — only argument shape is validated.

local function checknum(name, argn, v)
  if type(v) ~= "number" then
    error("bad argument #" .. argn .. " to '" .. name .. "' (number expected, got " .. type(v) .. ")", 3)
  end
end

local function checkstr(name, argn, v)
  if type(v) ~= "string" then
    error("bad argument #" .. argn .. " to '" .. name .. "' (string expected, got " .. type(v) .. ")", 3)
  end
end

_G.__native_render = {
  fill_rect = function(s, x, y, w, h, color)
    checknum("fill_rect", 2, x); checknum("fill_rect", 3, y)
    checknum("fill_rect", 4, w); checknum("fill_rect", 5, h)
    checknum("fill_rect", 6, color)
  end,
  round_rect = function(s, x, y, w, h, r, color)
    checknum("round_rect", 2, x); checknum("round_rect", 3, y)
    checknum("round_rect", 4, w); checknum("round_rect", 5, h)
    checknum("round_rect", 6, r); checknum("round_rect", 7, color)
  end,
  rect_border = function(s, x, y, w, h, thickness, color)
    checknum("rect_border", 2, x); checknum("rect_border", 3, y)
    checknum("rect_border", 4, w); checknum("rect_border", 5, h)
    checknum("rect_border", 6, thickness); checknum("rect_border", 7, color)
  end,
  gradient_border = function(s, x, y, w, h, thickness, color1, color2)
    checknum("gradient_border", 2, x); checknum("gradient_border", 3, y)
    checknum("gradient_border", 4, w); checknum("gradient_border", 5, h)
    checknum("gradient_border", 6, thickness)
    checknum("gradient_border", 7, color1); checknum("gradient_border", 8, color2)
  end,
  blit = function(s, src, x, y)
    if type(src) ~= "table" then
      error("bad argument #2 to 'blit' (surface expected, got " .. type(src) .. ")", 2)
    end
    checknum("blit", 3, x); checknum("blit", 4, y)
  end,
  glyph = function(s, x, y, row, color)
    checknum("glyph", 2, x); checknum("glyph", 3, y)
    checknum("glyph", 4, row); checknum("glyph", 5, color)
  end,
  text = function(s, x, y, str, color)
    checknum("text", 2, x); checknum("text", 3, y)
    checkstr("text", 4, str); checknum("text", 5, color)
  end,
  text_width = function(str) checkstr("text_width", 1, str); return #str * 8 end,
  line_height = function() return 16 end,
  push_clip = function(s, x, y, w, h)
    checknum("push_clip", 2, x); checknum("push_clip", 3, y)
    checknum("push_clip", 4, w); checknum("push_clip", 5, h)
  end,
  pop_clip = function() end,
  get_pixel = function(s, x, y)
    checknum("get_pixel", 2, x); checknum("get_pixel", 3, y)
    return 0
  end,
}

return M
