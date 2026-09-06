-- tests/ui/apps_hello_window.lua — apps/hello-window.lua is a real,
-- shipped app (spec/architecture.md "Windows and apps"), but nothing in
-- lua/aster/ is allowed to require it by name (ADR-007), so nothing
-- exercised it. Load it the same way a user's wm.lua would: by reference,
-- after requiring it themselves.

package.path = "lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua;" .. package.path
local fake = require("tests.ui.fakehost")
local aster = require("aster")

fake._set_info({ paths = { config = "/cfg", data = "/data", home = "/home" } })
host.write("/cfg/wm.lua", [[
local aster = require("aster")
return aster.wm.adopt {}
]])

aster.boot()
local wm = aster.state.wm

local app = require("apps.hello-window")
local win = wm:open { app = app, title = app.name }

-- draw() must run clean against the real (checking) fakehost renderer —
-- this is exactly the path that would have caught a typo'd argument (see
-- tests/ui/fakehost.lua's __native_render).
wm:render(host.surface())
assert(aster.state.windows[win.id] ~= nil, "hello-window's draw() must not crash")
assert(#fake.log_lines == 0, "hello-window's draw() must not log a crash")

app.key(win, "x", { ctrl = false, alt = false, shift = false, super = false })
assert(win.state.message == "you pressed: x", "app.key must update win.state as documented")

app.key(win, "escape", { ctrl = false, alt = false, shift = false, super = false })
assert(win.state.message == nil, "escape must clear the message")

print("apps_hello_window: PASS")
