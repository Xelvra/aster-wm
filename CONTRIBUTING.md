# Contributing to aster

Thanks for looking. This project is built to be read in an afternoon and changed in a
weekend — contributing should feel the same way.

## The way in is Lua, not Zig

Almost everything a first-time contributor wants to do lives in `config/wm.lua`, `apps/`, or
`lua/aster/`. You don't need to know Zig, and you don't need to understand the host contract,
to send a useful PR.

- Want a new look? → [`themes/`](themes/), or [`config/wm.lua`](config/wm.lua) to pick one
- Want to build something on top? → [`apps/`](apps/), start with
  [`apps/hello-window.lua`](apps/hello-window.lua) (30 lines)
- Want to fix WM behavior? → [`lua/aster/`](lua/aster/)

If you're comfortable in Zig, the backends (`src/backends/`), the renderer (`src/render/`)
and the [host contract](spec/host-contract.md) are where systems-level work happens. You
don't need to start there.

## Definition of done

```bash
zig build && zig build test
```

That's the whole bar. If it builds and the tests pass, it's reviewable.

There is no separate checklist to run by hand, no extra verification script, no
environment-specific step. If your PR needs something beyond those two commands to be
considered correct, that's a bug in our CI, not a requirement for you to work around —
please open an issue.

## The core has a line budget

`lua/aster/` is capped at 1,600 non-blank, non-comment lines, and `zig build test` fails if
you go over. This isn't bureaucracy — "you can read the whole window manager in an
afternoon" is the product, and a limit is the only thing that keeps a claim like that true
over a year of good individual commits.

If your change pushes it over, that's a signal the code belongs in `apps/`, not that the
budget is wrong. If you think it really is the budget that's wrong, open an issue and make
the case.

## Adding a theme

A theme is a file in [`themes/`](themes/) that returns a table of color overrides — any key
it doesn't set falls back to [`aster.wm.default_theme`](lua/aster/wm.lua). Copy
[`themes/nord.lua`](themes/nord.lua) as a starting point, drop your version in as
`themes/<name>.lua`, and point `config/wm.lua` at it: `wm.theme = require("themes.<name>")`.
`config/wm.lua` can also override drawing functions like `draw_frame` — that part isn't a
theme file's job, it's `config/wm.lua`'s.

`themes/*.lua` and `config/wm.lua` are code and they run with your full permissions. That's
the point, and it's also why you should read one before you run it.

## Adding an app

An app is a table with a `draw` function and up to three optional callbacks:

```lua
return {
  name = "hello",
  draw = function(win, surface) end,   -- required
  key  = function(win, key, mods) end, -- optional; return true if consumed
  text = function(win, str) end,       -- optional
  tick = function(win, now_ms) end,    -- optional; return true to request a redraw
}
```

Nothing in `lua/aster/` knows the name of any app, including the ones we ship. The editor
lives in `apps/` and gets loaded by `config/wm.lua` exactly the way yours will. A bar widget
(`widgets/`) is a different, smaller contract — `draw(bar, surface, x, y, h) -> width`,
registered into `wm.bar` instead of opened as a window — see
[`widgets/clock-widget.lua`](widgets/clock-widget.lua).

Start from [`apps/hello-window.lua`](apps/hello-window.lua). If your app needs something the
host contract doesn't expose yet, that's a host contract discussion (see below), not a
workaround.

## Changing the host contract

Changing [`spec/host-contract.md`](spec/host-contract.md) needs an ADR — see
[`spec/adr/`](spec/adr/) for the format and
[ADR-001](spec/adr/001-host-contract-not-a-kernel.md) as an example. Every function added
there is work for every present and future backend, so the bar is high and the discussion
happens before the code.

**Everything else needs no ADR at all.** Write the code, explain it in the PR description,
that's enough.

Before you propose a new host function, check whether it can be built on the ones that
already exist. The system monitor widget reads `/proc/meminfo` through `host.read` rather
than adding a metrics API; on backends without `/proc` it quietly disappears. That pattern
answers most requests.

## Working on a backend

Each backend implements [`spec/host-contract.md`](spec/host-contract.md) and must pass
everything in [`spec/conformance/`](spec/conformance/):

```bash
./tools/conformance.sh sdl      # or: wasm, drm, baremetal
```

A backend PR that doesn't pass conformance isn't done yet — the suite is the definition,
not a suggestion. If a capability genuinely doesn't apply to your backend (there are no
processes to spawn in a browser), report it in `host.info().caps` and return `"unsupported"`;
the test then passes because the backend told the truth, not because it was skipped.

## Before you open a PR

1. **Check [`good-first-issue`](https://github.com/Xelvra/aster-wm/labels/good-first-issue)**
   if you don't have something specific in mind.
2. **For anything bigger than a theme or a small fix, open an issue first.** Not required,
   but it saves you from writing 200 lines toward something that doesn't fit — especially
   for anything touching `lua/aster/wm.lua`.

## Code style

See [`spec/code-style.md`](spec/code-style.md). Short version: match what's already in the
file you're editing.

## Language

English — code, comments, commit messages, issues, PRs, everything. This is non-negotiable,
not out of preference but because it's the whole reason this project can have outside
contributors at all.

## What we're not looking for right now

- **GPU rendering paths.** The software renderer running identically on every backend,
  including bare metal, is the point.
- **A compositor**, or anything that would make `host.spawn` handle GUI clients instead of
  pty programs. See [ADR-008](spec/adr/008-spawn-is-pty-only.md).
- **A build system change.** `zig build` is the interface, keep it that way.
- **Networking**, in the host contract or in an app. It's not in the contract and adding it
  is a much bigger conversation than it looks.

If you think one of these is wrong, open an issue and make the case — this list isn't
permanent, just the current shape of things.

## Questions

Open an issue, or start a discussion. There's no wrong door.
