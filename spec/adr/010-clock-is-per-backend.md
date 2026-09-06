# ADR-010 — clock is a per-backend decision, not a shared helper

**Status:** accepted

## Context

`spec/host-contract.md` requires `host.clock()` to return `nil, "unsupported"` exactly when
`host.info().caps.clock` is `false`, and vice versa. Until now, `src/host/fs.zig` implemented
`clock()` as a single, infallible function shared by every backend (its own header said so:
"Filesystem, clock and log: identical on every backend"), and the sdl backend hardcoded
`caps.clock = true`.

That shape makes the contract's "the two must agree" requirement structurally impossible to
violate on the sdl backend (there is no code path that could ever disagree with a hardcoded
`true`), but also structurally impossible to *honor correctly* on a future backend with no
real-time clock: there was no way for such a backend to say so, short of forking the shared
`fs.zig` function itself. `caps.spawn` already solved the equivalent problem for
`host.spawn` by putting the capability behind a per-backend vtable function
(`Backend.spawnFn`, ADR-008); `clock` had no equivalent.

## Decision

`clock` moves into the backend vtable (`host.zig`'s `Backend.clockFn`, returning `?Clock`),
next to `info`/`surface`/`present`/`wait`. `fs.zig` keeps a plain helper, `realClock()`, that
reads the actual wall clock — any backend with a real one calls it from its own `clockFn`; a
future backend with none (or one that can't determine a timezone offset) returns `null`
instead. `bindings.zig`'s `lClock` calls `active_backend.clock()` and returns
`nil, "unsupported"` exactly when that's `null`.

## Consequences

- Every backend now implements a quintet — `info`/`surface`/`present`/`wait`/`clock` — not a
  quartet with clock/log/filesystem shared for free. Filesystem and log remain genuinely
  identical across backends (there's no reason a bare-metal filesystem read would differ from
  an SDL one) and stay in `fs.zig` as before.
- A backend with no notion of wall-clock time (bare metal without an RTC driver yet, say)
  can now honestly report `caps.clock = false` and return `null` from its own `clockFn`,
  instead of either lying about `true` or forking the shared helper.
- This is a change to `Backend`'s vtable shape, not to `spec/host-contract.md`'s twelve
  `host.*` functions themselves — no existing Lua-facing behavior changes, and no ADR was
  required by the letter of the rule that only a `host-contract.md` change needs one. It gets
  one anyway: extending the vtable is work every present and future backend has to account
  for, the same category of decision ADR-008 already treats as pre-emptively worth recording.
