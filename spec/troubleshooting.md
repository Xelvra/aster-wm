# Troubleshooting

Lessons from real incidents hit while building this repo — never a
narrative of what someone did, always a fact a future contributor would
otherwise have to rediscover the hard way. Code comments may reference an
entry by id (`see B5`); they must never retell it.

## B1 — This Zig 0.16.0 is not the "classic std.fs/std.time" Zig

**Symptom:** `std.fs.cwd()`, `std.time.milliTimestamp()`, `std.posix.getenv`,
`std.heap.GeneralPurposeAllocator` all fail to compile with "no member
named ...".

**Cause:** the Zig 0.16.0 available on this machine already carries Zig's
async `Io`-interface redesign. Filesystem and clock APIs moved onto
`std.Io.Dir` / `std.Io.Clock`, both requiring an explicit `Io` value on
almost every call; `std.heap.GeneralPurposeAllocator` was renamed
`std.heap.DebugAllocator`. None of this is optional or an unstable/nightly
flag — it is simply what `zig version` on this box resolves to.

**Fix:** the idiomatic entry point is "Juicy Main" —
`pub fn main(init: std.process.Init) !void { const io = init.io; const gpa
= init.gpa; ... }` — the runtime constructs exactly one `Io` implementation
and one debug-mode allocator for the whole process and hands them down;
application code should not construct its own. Filesystem calls go through
`std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))` and friends;
clocks through `std.Io.Clock.{real,awake}.now(io)`. Grep
`/usr/lib/zig/std/` directly before trusting a remembered Zig stdlib
signature in this repo — it is very likely wrong for this toolchain.
Context7's Zig coverage is the language reference, not per-function stdlib
API, so it will not catch this; a web search for "Zig 0.16 std.Io
migration" turns up real write-ups worth checking first.

## B2 — `luaL_newlib` does not survive `@cImport`

**Symptom:** `zig build` fails inside generated `cimport.zig` with
`expected type 'c_int', found 'c_ulong'` pointing at a `luaL_newlibtable`
expansion.

**Cause:** `luaL_newlib`/`luaL_newlibtable` are C macros computing an array
element count via `sizeof(l)/sizeof(l[0])`; Zig's C-macro translator turns
that `sizeof` arithmetic into a `usize` (`c_ulong`) result, which does not
implicitly narrow to the `c_int` `lua_createtable` expects.

**Fix:** never call `luaL_newlib`/`luaL_newlibtable` from Zig. Expand them
by hand: `lua_createtable(L, 0, @intCast(funcs.len - 1));
luaL_setfuncs(L, &funcs, 0);` — `luaL_setfuncs` itself is a real exported C
function, not a macro, and translates cleanly.

## B3 — `host.wait(0)` returning nil while the queue still has events

**Symptom:** `aster.frame()`'s drain loop (`while true do local e =
host.wait(0); if not e then break end ... end`, `lua/aster/loop.lua`)
sometimes stopped after one iteration even though more input was waiting —
observed while testing `host._inject` in isolation, where an injected
`key_down` event never reached Lua because it queued up behind an
unrelated OS-level window event.

**Cause:** `src/backends/sdl/backend.zig`'s `wait()` called `SDL_PollEvent`
once, and if the dequeued event's type had no mapping in `translate()`
(e.g. `SDL_WINDOWEVENT_SHOWN`), it returned `null` straight back to the
caller. Per spec/host-contract.md, `host.wait(0) == nil` is supposed to
mean "the queue is empty" — but here it also meant "the queue's next item
happened to be one we don't have a vocabulary word for", silently leaving
later, real events queued for up to a whole extra frame.

**Fix:** `wait()` loops internally — keep calling `SDL_PollEvent`/
`SDL_WaitEventTimeout` and skip anything `translate()` doesn't recognize,
returning `null` only once the underlying poll itself reports nothing left.
For the blocking (`timeout_ms > 0`) form this loop tracks a deadline via
`SDL_GetTicks()` so skipped events don't each restart the full timeout.

## B4 — `lua_pushstring` on a slice that isn't actually null-terminated

**Symptom:** an event's `key` field sometimes arrived in Lua with trailing
garbage characters (`"a"` came through as `"ak\x00..."`-shaped noise) —
only visible once `host._inject`-sourced key events (backed by a plain,
uninitialized fixed buffer) started exercising the path; real keyboard
input never showed it because `mapScancode()` only ever returns Zig string
literals, which happen to already be null-terminated in memory.

**Cause:** `src/host/bindings.zig`'s `pushEvent()` pushed `Event.key` (a
plain `[]const u8` slice, no null-termination guarantee) with
`lua_pushstring`, which treats its argument as a C string and reads until
it finds a zero byte — past the end of the actual key name into whatever
followed it in memory.

**Fix:** always push a Lua string with an explicit length —
`lua_pushlstring(L, ptr, len)` — never `lua_pushstring` — unless the
pointer is provably a literal or otherwise guaranteed null-terminated
(e.g. `[:0]const u8` from `std.fmt.allocPrintSentinel`). `text` was already
done this way; `key` was the one place still using the string-literal-only
form.

## B5 — sdl2-compat forwarding to SDL3 segfaults on a synthetic `SDL_TEXTINPUT`

**Symptom:** `SDL_PushEvent(&event)` with `event.type = SDL_TEXTINPUT`
segfaults inside `libSDL3.so.0`, reproducible identically under both
`SDL_VIDEODRIVER=dummy` and `x11` — i.e. not a headless-specific quirk.
Manually-pushed `SDL_KEYDOWN`/`SDL_WINDOWEVENT` events did not crash.

**Cause:** on this machine, "SDL2" (as `pkg-config sdl2` resolves it) is
actually `sdl2-compat`, a shim translating SDL2 API calls to a real SDL3
installation underneath. Something in that shim's translation of a
manually-injected text-input event dereferences a near-null pointer. This
is a bug in the shim, not in aster-wm's own code, and not something this
project can fix from the application side.

**Fix (and see ADR-009):** don't route test-only injected events through
the platform's real event queue at all. `host._inject` now stores events in
a small ring buffer owned by the Zig backend itself
(`src/backends/sdl/backend.zig`'s `pending`/`PendingEvent`), which `wait()`
drains before ever calling into SDL. This sidesteps the specific shim bug
and is arguably the right design regardless: a test-injection mechanism
should not depend on whatever OS/library queue happens to sit underneath
accepting synthetic input. ADR-009 additionally moves backend B1 off SDL2
(via this shim) onto SDL3 directly.

## B6 — An idle desktop was spinning a full core

**Symptom:** `SDL_VIDEODRIVER=dummy ./zig-out/bin/aster` with no input at all
measured ~99.6% CPU over a few seconds of wall time.

**Cause:** `src/main.zig`'s main loop called `state.frame()` back-to-back in
a tight `while (true)` with no blocking step, even when `frame()` returned
`"idle"` (nothing changed, safe to block). ADR-002 names this exact
antipattern as the reason the host owns the loop in the first place.

**Fix:** when `frame()` returns `"idle"`, the host now blocks via a new
`Sdl.idleWait(timeout_ms)`, which wraps `SDL_WaitEventTimeout(NULL, ms)`.
Passing `NULL` as the event pointer is what makes this safe: SDL still
consumes the wait but leaves the event in its own queue, so the very next
`wait()` call picks it up through the normal path instead of it being lost
here. A naive "peek-and-return" implementation using `SDL_PollEvent` or
`SDL_WaitEvent` would dequeue the event and require re-injecting it, adding
a second place events can go missing (compare with B3 above). The timeout
is ~1000ms so a time-based Lua widget still gets a tick roughly once a
second even with zero input.
