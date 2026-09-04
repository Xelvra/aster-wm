# Host Contract v1

Normative. A backend is conformant exactly when it implements this document and passes
`spec/conformance/`. Changing this document requires an ADR.

## Lifecycle

The host owns the main loop and calls into Lua:

```lua
aster.boot()      -- once, after the global `host` table is available
aster.frame()     -- repeatedly; returns "running" | "idle" | "quit"
aster.shutdown()  -- once, before the process exits
```

`"idle"` means nothing changed and the host may block until an event arrives — or for about
a second, so the clock keeps ticking. `"quit"` means stop calling `frame` and call
`shutdown`.

## Functions

```lua
host.info()                    -> Info
host.surface()                 -> Surface
host.present()                 -> nil
host.wait(timeout_ms)          -> Event | nil
host.now_ms()                  -> number
host.clock()                   -> Clock  | nil, err
host.read(path)                -> string | nil, err
host.write(path, data)         -> true   | nil, err
host.list(path)                -> {Entry}| nil, err
host.remove(path)              -> true   | nil, err
host.rename(from, to)          -> true   | nil, err
host.log(str)                  -> nil
```

Phase B adds `host.spawn`. Nothing else.

## Errors

Every fallible call returns `nil, err` where `err` is one of exactly these strings:

```
"not_found"  "permission"  "io"  "invalid"  "no_space"  "busy"  "unsupported"  "exists"
```

No free-form text. A localized description is the UI's job.

## host.info()

```lua
{
  backend = "sdl",              -- "sdl" | "drm" | "wasm" | "baremetal"
  format  = "xrgb8888",         -- v1: this value only
  pitch   = 7680,               -- bytes per row; informative, checked by conformance

  outputs = {                   -- always an array, even with one element
    { id = 1, x = 0, y = 0, w = 1920, h = 1080, scale = 1.0, primary = true },
  },

  paths = {                     -- absolute, no "~", no environment variables
    config = "/home/you/.config/aster",
    data   = "/home/you/.local/share/aster",
    home   = "/home/you",
  },

  caps = {                      -- every field always present
    clock  = true,              -- host.clock() returns a valid time
    spawn  = false,             -- phase B
    damage = false,             -- host.present(x, y, w, h) is supported
    inject = false,             -- host._inject() exists (test builds only)
  },
}
```

Call it at startup and after every `resize` event. Never cache it across a resize.

## Surface and drawing

`host.surface()` returns opaque userdata holding the backing buffer. Lua never dereferences
it; it passes it to the renderer (`require("aster.render")`).

v1 supports exactly one pixel format: `xrgb8888`, little-endian, 32 bpp. A backend whose
native format differs converts it itself.

`host.present()` sends the whole surface to the display. v1 has no damage tracking. If it
becomes a problem, `host.present(x, y, w, h)` will be added as an *optional* extension
announced through `caps.damage`.

## Events

```lua
host.wait(timeout_ms) -> Event | nil
```

Blocks for at most `timeout_ms`. `host.wait(0)` is a non-blocking poll and is the only form
`aster.frame()` uses.

```lua
{type="key_down",   key="a", mods={ctrl=true, alt=false, shift=false, super=false}}
{type="key_up",     key="a", mods={...}}
{type="text",       text="á"}                    -- UTF-8, after layout and IME
{type="mouse_move", x=100, y=200, dx=3, dy=-1}
{type="mouse_down", x=100, y=200, button="left"} -- left | right | middle
{type="mouse_up",   x=100, y=200, button="left"}
{type="scroll",     x=100, y=200, dx=0, dy=-1}
{type="resize",     w=1920, h=1080}              -- surface is invalid; call host.surface()
{type="focus",      focused=false}               -- host window gained or lost focus
{type="quit"}
```

`key_down` carries a **physical key name**, for shortcuts. `text` carries **resulting text**,
for typing. They are two separate events and a backend must deliver both — never one derived
from the other. Key names are listed in `spec/keys.md` and that list is normative too.

Keyboard layout (including switching between layouts) is the host's job. There is no
contract call for it.

On `focus` with `focused=false`, Lua clears its modifier state; a backend should send this
whenever the user leaves the window mid-chord.

## Filesystem

```lua
Entry = { name = "wm.lua", dir = false, size = 1234, mtime = 1756890000 }
```

- Paths are absolute, `/`-separated, UTF-8. No `~` expansion, no environment variables.
  Use `host.info().paths`.
- `host.write` is **atomic**: write to a temporary file in the same directory, then rename.
- `host.write` **creates missing parent directories**. This is why there is no `mkdir`.
- `mtime` is Unix seconds. It exists so the desktop can notice that `wm.lua` was edited by
  an external editor and offer to reload.
- `host.rename` onto an existing path returns `nil, "exists"`.

## Time

```lua
host.now_ms() -> number                                    -- monotonic, starts at 0
host.clock()  -> {unix_ms=…, utc_offset_min=…} | nil, err  -- wall clock
```

A backend with no real-time clock returns `nil, "unsupported"` and must report
`caps.clock = false`. The two must agree; conformance checks it.

## Log

```lua
host.log(str) -> nil
```

A privileged diagnostic sink — stderr, serial, `console.log`. It is never user-visible UI.

## Deliberately absent

Networking, audio, threads, clipboard, `mkdir`, `stat`, system metrics, keyboard layout
switching, hardware cursor planes. Each of them is either the host's business, buildable
from what's already here, or a separate conversation with an ADR attached.
