# ADR-013 — the wasm backend targets `wasm32-freestanding` with a vendored setjmp/longjmp shim, not `wasm32-wasi`

**Status:** accepted

## Context

M5 (`spec/adr/011-idle-blocking-is-not-yet-in-the-contract.md`'s "second backend") is the
wasm backend. Lua's own core (`ldo.c`) implements `lua_pcall`/error propagation with C's
`setjmp`/`longjmp` — not an implementation detail we can route around, since it's also what
gives aster's per-app crash isolation its floor (`spec/architecture.md`'s "an app that
crashes closes its own window").

No option below reaches for Emscripten: CONTRIBUTING.md rules out a second build system on
principle, and Emscripten's own asyncify is exactly what ADR-002 already rejected for the
frame loop. Every option was spiked against Zig 0.16's actual toolchain, not just read about.

## Options considered

1. **`wasm32-wasi` + plain `setjmp`/`longjmp`, no special flags.**
   - Pro: nothing to configure; this is what a normal libc port would do.
   - Con: doesn't compile at all. Zig's bundled libc headers refuse to declare `setjmp`/
     `longjmp` unless `__wasm_exception_handling__` is defined — the headers assume Wasm's
     exception-handling proposal is how `setjmp`/`longjmp` gets implemented on this target,
     not that it's unsupported outright.
2. **`wasm32-wasi` + `-mexception-handling -mllvm -wasm-enable-sjlj`** (the flag combination
   the headers themselves ask for).
   - Pro: the underlying mechanism genuinely works. LLVM lowers plain `setjmp`/`longjmp`
     calls to `__wasm_setjmp`/`__wasm_setjmp_test`/`__wasm_longjmp` — confirmed with a
     standalone (no-libc) reproducer: a 5-level-deep `longjmp` was thrown and caught
     correctly under Node.js.
   - Con: the specific runtime that provides those three functions
     (`libc/wasi/libc-top-half/musl/src/setjmp/wasm32/rt.c`, 83 lines, MIT via musl) fails to
     compile as part of Zig's own libc build. Zig's libc-builder compiles it with
     `-fno-unwind-tables -fno-asynchronous-unwind-tables` (a normal libc size optimization),
     and that specific combination breaks the exception-handling tag lowering: `fatal error:
     error in backend: undefined tag symbol cannot be weak`. Bisected at the `-cc1` level —
     identical flags except `-funwind-tables=2` compile clean, so the unwind-tables flag
     alone is the fork.
3. **Supply our own correctly-flagged copy of that same `rt.c` and let it win the link**,
   keeping the rest of `wasi-libc` untouched.
   - Pro: smallest possible diff if it worked — one vendored file, stock libc otherwise.
   - Con: doesn't work, confirmed by trying it. Zig's libc-builder compiles its own
     `wasi/…/rt.c` eagerly, as a side effect of the requested target/feature combination,
     before link-time symbol resolution is ever reached — a strongly-defined symbol supplied
     elsewhere on the command line doesn't pre-empt it the way ordinary archive-extraction
     semantics would. There is no `build.zig`-level hook that intercepts or skips a specific
     file inside Zig's own bundled libc build; that decision lives inside the compiler, not
     the project's public API surface.
4. **C++ exceptions as `LUAI_THROW`'s backend, instead of `setjmp`/`longjmp`** (Lua's `ldo.c`
   supports this as a built-in alternative).
   - Pro: sidesteps `setjmp`/`longjmp` and its lowering pass entirely.
   - Con: compiles (`-fwasm-exceptions`) but fails to link — `__cxa_allocate_exception`,
     `__cxa_throw`, `__wasm_lpad_context`, `_Unwind_CallPersonality`, `__cxa_begin_catch`,
     `__cxa_end_catch` are all undefined. Zig 0.16 doesn't ship a prebuilt `libc++abi`/
     `libunwind` for `wasm32-wasi` (tracked upstream as ziglang/zig#23560, still open at time
     of writing) — this path needs a C++ EH runtime that doesn't exist for this target yet,
     not just a flag.
5. **`wasm32-freestanding`: no `wasi-libc`, own libc shim, vendor just the `rt.c` runtime and
   compile it ourselves.**
   - Pro: sidesteps the libc-builder entirely instead of fighting it — nothing in this path
     depends on how Zig chooses to build its bundled `wasi-libc`. The `setjmp`/`longjmp`
     lowering mechanism itself (option 2's actual finding) is real and reusable here.
   - Con: the project now owns a small libc surface (allocator, a `string.h` subset, enough
     `math.h` for `lmathlib.c`, number formatting for `lstrlib.c`) instead of getting one for
     free.

None of options 1–4 is "wasm can't do this" — three of the four are specifically about
`wasm32-wasi`'s bundled libc: its headers, its libc-builder's fixed flags, its missing C++
runtime. Option 5 is the only one that stops depending on that libc at all.

## Decision

Target `wasm32-freestanding`. Bring only what Lua actually needs:

- A small platform module (`src/backends/wasm/libc.zig`) providing the libc
  surface Lua's core and stdlib actually call: an allocator (`malloc`/`realloc`/`free`),
  `string.h` (`memcpy`/`memset`/`memmove`/`strlen`/`strcmp`/…), enough of `math.h` for
  `lmathlib.c`, and `lstrlib.c`'s number-formatting needs. This is bounded by what Lua 5.4
  calls, not a general-purpose libc — Zig's own standard library covers most of the actual
  logic (allocator, formatting), so this is a thin adapter to the C ABI these call sites
  expect, not a from-scratch implementation.
- `musl`'s `setjmp/wasm32/rt.c` (83 lines, MIT), vendored verbatim into the repo and compiled
  by our own `build.zig` step with `-mexception-handling -mllvm -wasm-enable-sjlj
  -funwind-tables=2` — the exact flags confirmed to work in isolation. `THIRD-PARTY-NOTICES.md`
  gets an entry the same way `assets/font.ttf` does.
- Everything else Lua needs from `<setjmp.h>` (the `jmp_buf` layout, the `setjmp`/`longjmp`
  declarations) comes from a small header we own, not `wasi-libc`'s — we don't need the rest
  of what that header pulls in, and pulling it back in is exactly how option 2 broke.

## Consequences

- The wasm backend has no `wasi-libc` dependency, so it never touches Zig's libc-builder and
  the `-fno-unwind-tables` conflict is structurally avoided rather than worked around.
- The project owns a small libc surface it must maintain (`libc.zig` plus the vendored
  `rt.c`) — this is new maintenance burden `spec/troubleshooting.md` should track if it turns
  out to be a recurring source of bugs (missing symbol, ABI mismatch with what a newer Lua
  release expects).
- This is not a change to `spec/host-contract.md`'s twelve `host.*` functions — the wasm
  backend still implements exactly `info`/`surface`/`present`/`wait`/`clock`, same as SDL, and
  nothing here changes what a `require("aster")` caller sees. Per CONTRIBUTING.md's letter, no
  ADR is required — this gets one anyway, the same category of decision as ADR-008/ADR-010:
  extending or constraining what a backend is built from is work every future backend
  maintainer needs to know was deliberate, not accidental.
- If a future Zig release ships a working `libunwind`/`libc++abi` for `wasm32-wasi`
  (ziglang/zig#23560) or fixes the libc-builder's unwind-tables flag for this one file,
  switching back to plain `wasi-libc` becomes possible but is not required — the freestanding
  path has no known downside for a browser target that never needed WASI's filesystem/process
  surface in the first place (`host.*`'s own filesystem functions are implemented against the
  browser's storage directly, not through libc).
- ADR-011 (idle-blocking) is unaffected and still open — that fork is about `Backend`'s vtable
  shape, orthogonal to this one.
