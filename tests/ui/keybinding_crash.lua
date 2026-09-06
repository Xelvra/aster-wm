-- tests/ui/keybinding_crash.lua — a keybinding is config code, not an app,
-- but it must not be able to take the whole desktop down either:
-- spec/architecture.md's "Windows and apps" crash-isolation promise ("a
-- crashing app closes its own window rather than the desktop") has to
-- cover Super+whatever, the same as draw()/tick().
--
-- Without this, `wm:bind("super+x", function() error("boom") end)` throws
-- all the way out of aster.frame(), which src/main.zig calls via `try` —
-- taking down the whole process, not just logging and moving on.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
local wm = aster.wm.adopt {}
wm:bind("super+x", function() error("boom in keybinding") end)
wm:bind("super+y", function() end)
return wm
]])

aster.boot()

-- Must not throw out of dispatch.
aster.input.dispatch({
  type = "key_down", key = "x",
  mods = { ctrl = false, alt = false, shift = false, super = true },
})

assert(aster.state.wm, "a crashing keybinding must not tear down the wm singleton")
assert(#fake.log_lines > 0, "a crashing keybinding must be logged, never swallowed silently")
assert(fake.log_lines[#fake.log_lines]:find("boom in keybinding"),
  "the log must name the crash: " .. fake.log_lines[#fake.log_lines])

-- The desktop must still be fully responsive to a sibling keybinding
-- afterwards — the crash must not have wedged dispatch() or wm.keybindings.
local ran = false
aster.state.wm.keybindings["super+y"] = function() ran = true end
aster.input.dispatch({
  type = "key_down", key = "y",
  mods = { ctrl = false, alt = false, shift = false, super = true },
})
assert(ran, "a crashing keybinding must not stop other keybindings from working")

print("keybinding_crash: PASS")
