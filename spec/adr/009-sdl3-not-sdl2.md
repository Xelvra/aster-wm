# ADR-009 — SDL3, not SDL2, for the sdl backend

**Status:** accepted

## Context

The project's original design notes named SDL2 for the sdl backend (the
reference implementation, the one CI runs per spec/architecture.md's
backend table) without much justification beyond it being the obvious,
well-worn choice at the time.

While implementing `host._inject` (a test-only synthetic-event mechanism for
`spec/conformance/04_events.lua` and `07_resize.lua`, contract section 9.4),
a segfault surfaced deep inside `libSDL3.so.0` when pushing a synthetic
`SDL_TEXTINPUT` event through `SDL_PushEvent`. The development machine's
"SDL2" is actually `sdl2-compat`, a shim that forwards SDL2 API calls to a
real SDL3 installation underneath it — and that forwarding path has a bug
handling a manually-pushed text-input event specifically. Confirmed
reproducible independent of video driver (`SDL_VIDEODRIVER=dummy` and
`x11` both crash identically at the same address) — see
spec/troubleshooting.md entry B5 for the full diagnosis.

Real, non-injected SDL2 input already worked correctly for actual keyboard
and mouse input through the same shim — verified with a real window
screenshot before this bug was ever hit. The bug was narrowly confined to
one shim's translation of one synthetic event type, not a defect in
aster-wm's own event handling.

## Options considered

1. **Keep SDL2; work around the shim bug in our own code.** Route
   `host._inject` through an internal event queue in the backend instead of
   `SDL_PushEvent`, bypassing the buggy translation path for injected
   events only; real keyboard/mouse input is untouched.
   - Pro: smallest diff, spec unchanged, already implemented and passing
     all seven conformance tests at the point this ADR was written.
   - Con: leaves the project nominally "on SDL2" while, in practice, the
     only way to get SDL2 on this machine (and plausibly others as
     distributions phase SDL2 into a compatibility package) is through a
     shim forwarding to SDL3 anyway. That's exactly the kind of hidden
     translation layer that can carry more bugs like this one later.
2. **Switch to SDL3 directly for the sdl backend.**
   - Pro: talks to the library that's actually present and actively
     developed, with no translation layer in between to carry bugs;
     SDL3's API is a genuine improvement (clearer boolean-return error
     conventions, a simplified init/window/surface creation flow) worth
     having on its own merits, not just to dodge one crash.
   - Con: `src/backends/sdl/backend.zig` needs a real rewrite, not a patch
     — init, window/surface creation, and every event-type constant differ
     between SDL2 and SDL3; spec/architecture.md's backend table needs
     updating to match; SDL3's Emscripten/wasm support is less
     battle-tested than SDL2's, which matters for the future wasm backend
     and has to be re-evaluated when that milestone starts, not assumed
     away now.
3. **Vendor a specific SDL2 release**, bypassing whatever "SDL2" resolves
   to at the system level. Rejected outright: it contradicts the project's
   own build promise (`zig build && zig build test` works against whatever
   the platform provides) and reintroduces exactly the vendored-dependency
   weight the project is trying to avoid by depending on the host's own
   libraries.

## Decision

The sdl backend moves to **SDL3**. `src/backends/sdl/backend.zig` is rewritten
against the SDL3 API — not patched — and `spec/architecture.md`'s backend
table is updated to say SDL3. The internal event queue built for
`host._inject` is kept regardless of this decision: it is the right design
for a test-injection mechanism on its own merits (it should not depend on
whatever OS/library queue happens to sit underneath accepting synthetic
input at all), not merely a shim workaround that this migration makes moot.

## Consequences

- Building `aster` now requires a real SDL3 install. On a machine that
  only has SDL2 (no SDL3, no compat shim), the build fails — a real,
  knowingly-accepted dependency shift, not a silent trap; call it out in
  README/CONTRIBUTING when those are next touched.
- The future wasm backend's SDL story needs re-evaluating against SDL3's
  Emscripten support specifically when that milestone starts. Flagged here
  so it is not rediscovered from scratch.
- Every SDL call in the backend is rewritten and re-verified against
  `spec/conformance/01` through `07` as part of this change, not ported
  blind from the SDL2 version.
