# ADR-011 — idle-blocking is not yet in the host contract

**Status:** accepted (records a known gap; does not close it)

## Context

ADR-002 puts the host in charge of the frame loop specifically so it can block instead of
spinning when nothing changed (`"idle"`, see B6 in `troubleshooting.md`).
`spec/host-contract.md` describes the resulting behavior in prose — `host.wait(timeout_ms)`
"may block until an event arrives — or for about a second" — but that sentence describes
`host.wait`, and the actual idle-blocking call in `src/main.zig` is `sdl.idleWait(1000)`, a
method on the concrete `Sdl` type, not a function in `Backend`'s vtable
(`src/host/host.zig`). `main.zig` also constructs `sdl_backend.Sdl` directly; there is no
backend-selection mechanism (build flag, comptime switch) at all yet.

None of this is a bug today — there is exactly one backend, so "the concrete type" and "the
only backend" are the same thing, and nothing exercises the gap. It becomes a real decision
the moment a second backend (wasm, per the project's roadmap) exists and `main.zig` needs to
run against either one.

## Decision

Defer the actual fix, but record the fork now so M5 doesn't rediscover it as a surprise:

- **Option A:** add `idleFn` to `Backend`'s vtable, alongside `info`/`surface`/`present`/
  `wait`/`clock`. Every backend implements idle-blocking its own way (SDL's
  `SDL_WaitEventTimeout(NULL, ms)`; a wasm backend would instead do nothing, since
  `requestAnimationFrame` already only calls in when the browser wants a frame).
- **Option B:** `main.zig` itself forks per backend (an `if` or comptime switch selecting
  which concrete type to construct and how to idle-wait it), keeping `Backend`'s vtable at
  its current five functions.

Option A keeps `main.zig` backend-agnostic, matching how `info`/`surface`/`present`/`wait`/
`clock` already work, at the cost of a sixth vtable function every future backend must
implement (even a wasm backend that does nothing there). Option B keeps the vtable exactly as
poor as the contract intends, at the cost of `main.zig` no longer being one generic loop.

No option is chosen yet — this is written down so the choice is made deliberately when M5
starts, not as a side effect of whichever way is fastest to get wasm building.

## Consequences

- Until this is resolved, `main.zig` remains SDL-specific by construction, and a
  backend-selection mechanism does not exist. Both are fine with one backend; both are
  blockers for a second one.
- Whichever option is picked, it is a change to `Backend`'s vtable shape or to `main.zig`'s
  structure, not to `spec/host-contract.md`'s twelve `host.*` functions — no ADR is strictly
  required by the letter of the rule, but one should be written anyway when this is resolved,
  the same way ADR-010 recorded `clockFn`'s addition.
