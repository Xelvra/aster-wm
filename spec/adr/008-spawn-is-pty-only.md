# ADR-008 — host.spawn is pty-only

**Status:** accepted (pre-emptive; the function itself lands in phase B)

## Context

To be a desktop rather than a demo, aster has to run other programs. That means adding
`host.spawn` to the contract in phase B.

This is the single most dangerous change in the project's life. `host.spawn` is one small
step from "let's let spawned programs draw", which is one small step from shared buffers,
which is a compositor, which is Wayland. At that point the project is a worse Hyprland,
built by one person, and the thing that made it worth existing — that you can read and
rewrite the whole window manager — is gone under a protocol implementation.

The danger is not that someone will propose it as a bad idea. It is that it will arrive as
a series of individually reasonable pull requests.

## Decision

`host.spawn` handles **text programs over a pty. Nothing else.**

- No GUI clients, no compositor, no `wl_surface`, no shared buffers, no window handles
  passed across the boundary.
- The interface is bytes in, bytes out, plus resize and signals:
  `write`, `read`, `resize(cols, rows)`, `kill(sig)`, `status()`.
- A backend with no pty (WebAssembly, bare metal) reports `caps.spawn = false` and returns
  `"unsupported"`. The UI adapts.

This ADR is written before the code so that it is already the status quo when the question
comes up.

## Consequences

- The terminal emulator is written in Lua, on top of this, like any other app.
- The same `wm.lua` runs on Linux with a terminal and on bare metal without one — which is
  the best available proof that the host contract is real and not just a diagram.
- We will refuse otherwise good pull requests that cross this line, and `CONTRIBUTING.md`
  says so in advance so nobody wastes a weekend.
