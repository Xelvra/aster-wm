# Architecture

Two pages. If you need more than this to understand the system, that's a bug in the system,
not in the document.

## The shape

```
  host (Zig)          owns the loop:  boot() → frame() → frame() → … → shutdown()
      │
      │  host.*  — twelve functions, spec/host-contract.md
      ▼
  ~/.config/aster/wm.lua      ← this IS the window manager
      │
      │  require("aster")
      ▼
  lua/aster/   core, under 1,600 lines: loop wm bar launcher input render
      │
      │  require("apps.*")
      ▼
  apps/        editor, files, repl, and whatever you write
```

## Four rules

**1. The host contract is the only boundary.** Lua calls nothing outside `host.*` and
`require("aster.*")`. A backend never reaches into Lua state except through `aster.boot`,
`aster.frame` and `aster.shutdown`. Break this and "mount it anywhere" stops being true,
which is the only reason the project exists.

**2. The contract is deliberately poor.** Twelve functions. Every additional one is another
thing every future backend has to implement. Adding one is an ADR, not a commit.

**3. Policy up, mechanism down.** The renderer knows `fill_rect`, `glyph` and `clip`. It
must never know what a window is. The moment the renderer knows about windows, the window
manager is no longer in Lua and the project is dead.

**4. Nothing you can see is hardcoded in Zig.** The bar, the window frame, the cursor, the
launcher, the error bubble after a failed reload — all of it is drawn from Lua. Zig supplies
rectangles and glyphs. If you catch yourself writing something in Zig that has a *shape*,
you broke rule 3 before you noticed.

## The host owns the loop

The host calls into Lua, not the other way around:

```
st = aster.frame()
  "running"  → a frame was drawn and presented
  "idle"     → nothing changed; the host may block until an event arrives
  "quit"     → shut down
```

This is why the WebAssembly backend works without asyncify: in a browser the loop belongs
to `requestAnimationFrame` and always will. See
[ADR-002](adr/002-host-drives-the-frame.md).

## Reload preserves state

`wm.lua` is the window manager, so reloading it replaces the *code* — never the *windows*.
Window state lives in `aster.state`, which is created once at boot and never replaced.
`aster.wm.adopt()` returns the same instance every time, resetting only what a previous
config had overridden: keybindings, drawing methods, theme, bar widgets.

If the file doesn't compile, the previous version keeps running and an error bubble says
which line is wrong. If it compiles but throws, the last known-good source is re-applied.
The desktop is never left blank. See [ADR-003](adr/003-reload-preserves-state.md).

## Windows and apps

A window has an integer `id`. The title is just an attribute — it can change, and two
windows can share one.

An app is a table with a `draw` function and optional `key`, `text` and `tick` callbacks.
The core never knows the name of any app, including the ones shipped in this repo; the
editor, the file browser and the REPL are loaded by `config/wm.lua` exactly the way a
third-party app is. Each app draws inside a clip rectangle, so a buggy app can't paint over
its neighbours, and a crashing app closes its own window rather than the desktop.

## Backends

| Backend | Loop | Notes |
|---|---|---|
| SDL2 | own `while` loop | reference implementation, the one CI runs |
| DRM/KMS + evdev | own loop, page flip | needs seatd/libseat and VT handling |
| WebAssembly | `requestAnimationFrame` | the reason the loop is inverted |
| bare metal | own loop, `hlt` when idle | no `spawn`; the same `wm.lua` still runs |

A backend is done when it passes `spec/conformance/`. Capabilities it genuinely lacks are
declared in `host.info().caps` and return `"unsupported"` — the desktop adapts (the bar
shows uptime instead of a clock) rather than breaking.

## What is deliberately absent

No compositor. No Wayland or X11 client support. No GPU path. No networking. No sandbox —
`wm.lua` runs with your full permissions, because a sandbox is exactly the thing that would
make it unhackable.
