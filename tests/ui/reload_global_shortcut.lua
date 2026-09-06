-- tests/ui/reload_global_shortcut.lua — ADR-003: Super+Shift+R always
-- triggers a reload, bypassing wm.keybindings entirely, so it still works
-- even when the running config never bound it (or bound nothing at all).
-- It must match modifiers exactly, the same as any user keybinding —
-- Ctrl+Super+Shift+R must NOT also trigger it, leaving that combination
-- free for a user to bind separately.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x111111 }
return wm
]])
aster.boot()

-- Edit the file without calling aster.reload() directly — only the
-- shortcut should pick it up.
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm.theme = { accent = 0x222222 }
return wm
]])
assert(aster.state.wm.theme.accent == 0x111111, "editing the file alone must not reload")

aster.input.dispatch({
  type = "key_down",
  key = "r",
  mods = { ctrl = true, alt = false, shift = true, super = true },
})
assert(aster.state.wm.theme.accent == 0x111111, "ctrl+super+shift+r must NOT trigger the global reload shortcut")

aster.input.dispatch({
  type = "key_down",
  key = "r",
  mods = { ctrl = false, alt = false, shift = true, super = true },
})

assert(aster.state.wm.theme.accent == 0x222222, "super+shift+r must trigger a reload")

print("reload_global_shortcut: PASS")
