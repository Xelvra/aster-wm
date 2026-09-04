# ADR-002 — The host drives the frame

**Status:** accepted

## Context

The obvious design has Lua own the main loop: a non-blocking `host.poll()` called in a
`while true` loop that polls, updates and renders.

That cannot work in a browser. Under WebAssembly the main loop belongs to
`requestAnimationFrame`; a Lua-side infinite loop would need emscripten's asyncify, which is
slow, fragile, and would make the WebAssembly backend a special case in a project whose only
selling point is that the same code runs everywhere.

It is also bad on native backends: a non-blocking poll plus a full-frame present per
iteration means an idle desktop burns a core.

## Decision

The host owns the loop and calls into Lua:

```lua
aster.boot()      -- once
aster.frame()     -- repeatedly; "running" | "idle" | "quit"
aster.shutdown()  -- once
```

There is no `host.poll()`. `host.wait(timeout_ms)` replaces it, and `host.wait(0)` is the
non-blocking form `aster.frame()` uses. `"idle"` tells the host it may block until an event
arrives.

## Consequences

- The WebAssembly backend is `requestAnimationFrame(() => aster_frame())`. No asyncify, no
  special case.
- An idle desktop costs nothing, and how to idle is each host's business — `SDL_WaitEvent`,
  `poll()` on a DRM fd, `hlt` on bare metal.
- Lua cannot assume it will get control back at a fixed interval. Anything time-based reads
  `host.now_ms()` instead of counting frames.
- The contract has one event function instead of two.
