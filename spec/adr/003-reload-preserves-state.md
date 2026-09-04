# ADR-003 — Reload preserves state

**Status:** accepted

## Context

The core product claim is that you edit `wm.lua` while the desktop runs. But `wm.lua` *is*
the window manager, so naively re-executing it constructs a fresh, empty one — and every
`Ctrl+S` would close every window. The demo that proves this isn't a config file (rewrite
`draw_frame`, save, watch the *same* windows redraw differently) could not be recorded at
all.

Separately, treating a broken config as "fall back to the built-in default" means a typo
mid-edit throws away your session.

## Decision

**State survives, code is replaced.**

- `aster.state` is created once in `aster.boot()` and never replaced. Windows, workspaces
  and focus live there.
- `aster.wm.adopt(opts)` returns the same instance on every call. Before returning it, it
  resets everything a previous config had overridden — keybindings, drawing method overrides,
  theme, bar widgets — so that removing a function from the config actually removes its
  effect. It resets nothing in `aster.state`.
- Reload protocol: read → compile → snapshot → run in `pcall` → verify → commit. A compile
  error keeps the running config untouched and shows the line. A runtime error rolls back
  to the last known-good source. Only if that also fails do we fall back to the built-in
  default.
- The error bubble is drawn from Lua and says `keeping previous config — desktop untouched`.

## Consequences

- The two headline demos are recordable, because the windows stay.
- Users can experiment without fear, which is the actual product.
- `tests/ui/` must assert that reloading a file produces a state identical to starting fresh
  with that file, windows aside. Without that test this decision rots silently.
- Apps keep private state in `win.state`, which the core never touches, so an app survives a
  reload with its contents intact.
