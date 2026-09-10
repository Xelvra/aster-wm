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
  apps/        editor, and whatever you write
```

## Four rules

**1. The host contract is the only boundary.** Lua calls nothing outside `host.*`,
`require("aster.*")`, and two infrastructure globals the host installs before boot —
`__native_render` (the renderer core wraps, `lua/aster/render.lua`) and
`__aster_default_config` (the seed config `lua/aster/loop.lua` falls back to) — a closed
list, enforced by `tools/check-contract-boundary.sh`'s allow-list, not open to growth by
convention. A backend never reaches into Lua state except through `aster.boot`,
`aster.frame` and `aster.shutdown`. Break this and "mount it anywhere" stops being true,
which is the only reason the project exists.

**2. The contract is deliberately poor.** Twelve functions. Every additional one is another
thing every future backend has to implement. Adding one is an ADR, not a commit.

**3. Policy up, mechanism down.** The renderer knows `fill_rect`, `glyph` and `clip`. It
must never know what a window is. The moment the renderer knows about windows, the window
manager is no longer in Lua and the project is dead.

**4. Nothing you can see is hardcoded in Zig.** The bar, the window frame, the launcher, the
error bubble after a failed reload — all of it is drawn from Lua. Zig supplies rectangles and
glyphs. If you catch yourself writing something in Zig that has a *shape*, you broke rule 3
before you noticed. (A cursor isn't drawn by anything yet — SDL and the browser both supply
their own; a backend that needs one drawn, like DRM/KMS, draws it from Lua too, the same as
everything else here.)

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
which line is wrong. If it compiles but throws — or doesn't return the adopted instance —
the last known-good source is re-applied; if that also fails, the built-in default is the
last safety net. The desktop is never left blank. See
[ADR-003](adr/003-reload-preserves-state.md).

`Super+Shift+R` reloads and `Escape` dismisses the error bubble; both bypass
`wm.keybindings` entirely (`lua/aster/input.lua`), so they work even with a broken or empty
config.

The external-edit watch polls `wm.lua`'s mtime, which `host-contract.md` defines in whole
Unix seconds — two saves inside the same second are indistinguishable, so the second one is
only picked up once a third change (or the next second boundary) produces a different mtime.
If `wm.lua` is deleted while the desktop is running, the watch notices the mtime disappear
but does not itself trigger a reload or fall back to the built-in default — the last
successfully loaded config keeps running untouched until the file reappears or a manual
reload is triggered.

## Windows and apps

A window has an integer `id`. The title is just an attribute — it can change, and two
windows can share one. Every window is floating — no tiling layout exists, and that is a
stage rather than a verdict
([ADR-016](adr/016-every-window-floats-tiling-is-deferred.md)). Every window does belong to
a workspace (`win.ws`, defaulting to whichever workspace was current when
`wm:open` created it) — `wm:goto_workspace(i)`/`wm:move_to_workspace(win, i)` switch and
reassign it; `wm:render`/`wm:tick`/`wm:window_at` only see the current workspace's windows.

An app is a table with a `draw` function and optional `key`, `text`, `tick` and `click`
callbacks. The core never knows the name of any app, including the ones shipped in this
repo; the editor is loaded by `config/wm.lua` exactly the way a third-party app is. Each app
draws inside a clip rectangle, so a buggy app can't paint over its neighbours, and a crashing
app closes its own window rather than the desktop. That clip rectangle is the app's own full
`win.x/y/w/h`, not inset for the frame drawn around it — the title bar and border
(`lua/aster/wm.lua`'s `default_draw_frame`) are chrome painted over the app's content
afterward, not a mask the renderer cuts the content to; there is no rounded-rect clip mask to
cut one with. An app that needs the title bar out of its way (most do) offsets its own
content by `theme.title_h + theme.border` — the core never insets the clip rect for it.
`title_bar_rect`'s own bottom edge sits at `win.y + border + title_h`, so anything less
leaves a strip where whatever's behind the window shows through (see B42 in
`spec/troubleshooting.md`).

Global keybindings are always checked before `app.key` — a window manager binding like
`super+q` must work even inside a buggy or malicious app, the same way i3/sway/awesome grab
their own shortcuts first. `app.key`'s return value is not consumed by anything. `app.key`
only ever fires for `key_down`; the contract's `key_up` and `scroll` events reach
`lua/aster/input.lua` but are not currently routed to any app.

`app.click(win, x, y)` fires on a left click inside the window's content area (below the
title bar, and only once focus, drag and close-button hit-testing have all had first refusal
— `lua/aster/input.lua`'s `mouse_down` handler). Same discipline as `app.key`: optional,
return value unused, a crash is caught by `wm:guard` and closes only that window.

## Typography

Text is drawn with a bundled TrueType font (`assets/font.ttf`, `@embedFile`-d, never read
through `host.read`), rasterized and cached by codepoint in `src/render/font.zig` — Lua never
sees a glyph bitmap, only `r.text`/`r.text_width`/`r.line_height`. `@embedFile` makes a
missing font a build error, not a runtime state; if the *bundled* font fails to parse, the
built-in bitmap font (`font_data.zig`) takes over instead and `host.log` says why — a font
problem degrades the desktop, it never stops it from booting. See
[ADR-006](adr/006-ttf-rasterizer-bitmap-fallback.md).

## Backends

| Backend | Loop | Notes |
|---|---|---|
| SDL3 | own `while` loop | reference implementation, the one CI runs (ADR-009) |
| WebAssembly | `requestAnimationFrame` | the reason the loop is inverted; freestanding, own libc (ADR-013) |
| DRM/KMS + evdev | own loop, page flip | needs seatd/libseat and VT handling — not built yet |
| bare metal | own loop, `hlt` when idle | no `spawn`; the same `wm.lua` still runs — not built yet |

A backend is done when it passes `spec/conformance/`. Capabilities it genuinely lacks are
declared in `host.info().caps` and return `"unsupported"` — the desktop adapts (the bar
shows uptime instead of a clock) rather than breaking. A conformance script that needs a
capability the backend under test doesn't have signals that by erroring with a message
starting `"SKIP:"`, which `aster-conformance` reports as a declared skip (exit code 2), not a
pass — a capability a backend genuinely can't run becomes a manual release-checklist item,
never something that silently looks green.

The two-binary split (a release build, and a `-conformance` build with `build_options.conformance`
so it alone exposes `host._inject`) keeps that test-only surface out of every real build —
`aster`/`aster-conformance` on the SDL side, `aster-wasm`/`aster-wasm-conformance` on wasm.
`__native_render.get_pixel` is a second, always-present test hook, unrelated to the
conformance-only split — it exists purely so `spec/conformance/02_surface.lua` can read back a
pixel it just wrote; no app or theme needs it, and none should use it.

## What is deliberately absent

No compositor. No Wayland or X11 client support. No GPU path. No networking. No sandbox —
`wm.lua` runs with your full permissions, because a sandbox is exactly the thing that would
make it unhackable.
