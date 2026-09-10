-- tests/ui/fakehost.lua — a reference implementation of the host contract
-- (spec/host-contract.md), for running lua/aster/*.lua and apps/*.lua under
-- a plain host Lua 5.4 interpreter, no graphics, no real backend. Load this
-- before requiring "aster" — it sets the `host` and `__native_render`
-- globals every module in this repo assumes exist.
--
-- Doubles as executable documentation of the contract: if you don't know
-- what `host.rename` is supposed to do, the five lines below are the answer.

local M = {}

-- ADR-015: src/host/lua.zig pushes this global from the embedded
-- config/wm.lua on every real backend (src/host/modules.zig's
-- pushDefaultConfig); a minimal stand-in is enough here since tests/ui/
-- only checks that loop.lua's M.boot() writes *something* when no config
-- exists yet, never that it matches the shipped config/wm.lua verbatim.
_G.__aster_default_config = [[
local aster = require("aster")
return aster.wm.adopt {}
]]

-- ---- in-memory "filesystem" ------------------------------------------

local fs = {} -- path -> { data = string, mtime = number }
local mtime_clock = 0

-- path -> error string: makes host.read(path) fail with something other
-- than "not_found" (permission, io, busy, invalid), the way a real
-- filesystem can even when the file exists — see B14 in troubleshooting.md.
local read_errors = {}
function M._set_read_error(path, err) read_errors[path] = err end

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

-- A distinct metatable marks a value as "actually came from host.surface()",
-- as opposed to any other table (a window, an app) that an app might pass
-- by mistake. The real backend distinguishes a surface by Lua type
-- (LUA_TLIGHTUSERDATA vs. everything else, src/host/bindings.zig's
-- surfaceArg) — a plain `{}` here can't reproduce that distinction, since
-- both a surface and a window are ordinary tables in this fake.
local SURFACE_MT = {}

_G.host = {
  info = function() return info end,
  surface = function() return setmetatable({ _clip_depth = 0 }, SURFACE_MT) end, -- opaque; tests/ui/ never draws pixels
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
    if read_errors[path] then return nil, read_errors[path] end
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

-- Ranges mirror src/host/bindings.zig's checkI32/checkU32 (see B17 in
-- spec/troubleshooting.md): x/y are i32, everything else __native_render
-- takes (w, h, thickness, radius, codepoint/row, color) is u32.
local I32_MIN, I32_MAX = -2147483648, 2147483647
local U32_MAX = 4294967295

-- Counts UTF-8 codepoints, not bytes: the real renderer (src/render/renderer.zig's
-- textWidth) advances one glyph per codepoint, so a multi-byte character
-- must count once here too, not once per byte.
local function utf8_len(s)
  local n, i = 0, 1
  while i <= #s do
    local b = s:byte(i)
    if b >= 0xf0 then
      i = i + 4
    elseif b >= 0xe0 then
      i = i + 3
    elseif b >= 0xc0 then
      i = i + 2
    else
      i = i + 1
    end
    n = n + 1
  end
  return n
end

local function checkstr(name, argn, v)
  if type(v) ~= "string" then
    error("bad argument #" .. argn .. " to '" .. name .. "' (string expected, got " .. type(v) .. ")", 3)
  end
end

local function checksurface(name, argn, v)
  if type(v) ~= "table" or getmetatable(v) ~= SURFACE_MT then
    error("bad argument #" .. argn .. " to '" .. name .. "' (surface expected, got " .. type(v) .. ")", 3)
  end
end

local function checki32(name, argn, v)
  if type(v) ~= "number" or v % 1 ~= 0 or v < I32_MIN or v > I32_MAX then
    error("bad argument #" .. argn .. " to '" .. name .. "' (value does not fit in a 32-bit coordinate)", 3)
  end
end

local function checku32(name, argn, v)
  if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > U32_MAX then
    error("bad argument #" .. argn .. " to '" .. name .. "' (value does not fit in an unsigned 32-bit size)", 3)
  end
end

-- Mirrors src/host/bindings.zig's optAlpha — an optional trailing 0-255
-- argument, defaulting to opaque (255) when omitted.
local function checkalpha(name, argn, v)
  if v == nil then return end
  if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > 255 then
    error("bad argument #" .. argn .. " to '" .. name .. "' (alpha must be 0-255)", 3)
  end
end

_G.__native_render = {
  fill_rect = function(s, x, y, w, h, color, alpha)
    checksurface("fill_rect", 1, s)
    checki32("fill_rect", 2, x); checki32("fill_rect", 3, y)
    checku32("fill_rect", 4, w); checku32("fill_rect", 5, h)
    checku32("fill_rect", 6, color); checkalpha("fill_rect", 7, alpha)
  end,
  round_rect = function(s, x, y, w, h, r, color, alpha)
    checksurface("round_rect", 1, s)
    checki32("round_rect", 2, x); checki32("round_rect", 3, y)
    checku32("round_rect", 4, w); checku32("round_rect", 5, h)
    checku32("round_rect", 6, r); checku32("round_rect", 7, color)
    checkalpha("round_rect", 8, alpha)
  end,
  rect_border = function(s, x, y, w, h, thickness, color)
    checksurface("rect_border", 1, s)
    checki32("rect_border", 2, x); checki32("rect_border", 3, y)
    checku32("rect_border", 4, w); checku32("rect_border", 5, h)
    checku32("rect_border", 6, thickness); checku32("rect_border", 7, color)
  end,
  gradient_border = function(s, x, y, w, h, thickness, color1, color2)
    checksurface("gradient_border", 1, s)
    checki32("gradient_border", 2, x); checki32("gradient_border", 3, y)
    checku32("gradient_border", 4, w); checku32("gradient_border", 5, h)
    checku32("gradient_border", 6, thickness)
    checku32("gradient_border", 7, color1); checku32("gradient_border", 8, color2)
  end,
  glyph = function(s, x, y, row, color)
    checksurface("glyph", 1, s)
    checki32("glyph", 2, x); checki32("glyph", 3, y)
    checku32("glyph", 4, row); checku32("glyph", 5, color)
  end,
  text = function(s, x, y, str, color)
    checksurface("text", 1, s)
    checki32("text", 2, x); checki32("text", 3, y)
    checkstr("text", 4, str); checku32("text", 5, color)
  end,
  text_width = function(str) checkstr("text_width", 1, str); return utf8_len(str) * 8 end,
  line_height = function() return 16 end,
  -- Mirrors src/render/surface.zig's max_clip_depth so a test that pushes
  -- past it here behaves the way it would against the real renderer.
  push_clip = function(s, x, y, w, h)
    checksurface("push_clip", 1, s)
    checki32("push_clip", 2, x); checki32("push_clip", 3, y)
    checku32("push_clip", 4, w); checku32("push_clip", 5, h)
    if s._clip_depth < 8 then s._clip_depth = s._clip_depth + 1 end
  end,
  pop_clip = function(s)
    checksurface("pop_clip", 1, s)
    if s._clip_depth > 0 then s._clip_depth = s._clip_depth - 1 end
  end,
  -- clip_depth/restore_clip (see B32 in spec/troubleshooting.md): a
  -- reference model of src/render/surface.zig's Surface.restoreClip, used
  -- by lua/aster/render.lua's `clipped` to self-heal an unbalanced fn.
  clip_depth = function(s)
    checksurface("clip_depth", 1, s)
    return s._clip_depth
  end,
  restore_clip = function(s, depth)
    checksurface("restore_clip", 1, s)
    checku32("restore_clip", 2, depth)
    if depth < s._clip_depth then s._clip_depth = depth end
  end,
  get_pixel = function(s, x, y)
    checksurface("get_pixel", 1, s)
    checki32("get_pixel", 2, x); checki32("get_pixel", 3, y)
    return 0
  end,
}

return M
