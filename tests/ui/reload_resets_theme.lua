-- tests/ui/reload_resets_theme.lua — ADR-003 names theme among what a
-- config reload must reset (alongside keybindings, drawing method
-- overrides, bar widgets): removing an override from the config must
-- actually remove its effect, not leave the last-seen value stuck. Since
-- D4 unified theme defaults (lua/aster/wm.lua's default_theme), "removed"
-- means "back to the default", not "nil" — every theme key always has a
-- real value now, default or overridden.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })

host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0xbbbbbb }
wm:bind("super+x", function() end)
return wm
]])
aster.boot()

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

assert(aster.state.wm.theme.accent == 0xbbbbbb, "theme override must take effect")
assert(count(aster.state.wm.keybindings) == 1, "keybinding override must take effect")

-- v2 drops both overrides entirely.
host.write("/cfg/wm.lua", [[
local aster = require("aster")
return aster.wm.adopt {}
]])
aster.reload()

assert(count(aster.state.wm.keybindings) == 0, "removing a keybinding from the config must remove it")
local aster_wm = require("aster.wm")
assert(aster.state.wm.theme.accent == aster_wm.default_theme.accent,
  "removing a theme override from the config must fall back to the default, not leave the old override stuck")

print("reload_resets_theme: PASS")
