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

## B7 — A typo in `draw_frame` took the whole process down, not just a window

**Symptom:** a config redefining `wm:draw_frame` with a bug (e.g. indexing a
missing theme field) crashed `aster` outright — `lua error: ... attempt to
index a nil value`, exit code 1 — rather than leaving the desktop running.

**Cause:** `lua/aster/wm.lua`'s `M:render` called `self:draw_frame(win)`
directly, with no `pcall`, while every app callback (`draw`/`key`/`text`/
`tick`) already goes through `wm:guard`. `draw_frame` is shared across every
open window and is exactly the function the README and demo GIFs tell users
to redefine live, so a bug in it is one of the most likely runtime errors to
hit in practice — and it was also the one with no safety net at all.

**Fix:** `M:render_frame` wraps `self:draw_frame(win)` in its own `pcall`,
separate from `wm:guard`. On error it logs and swaps `self.draw_frame` to
`M.default_draw_frame` for good, then keeps going — closing the window would
be wrong here, since the bug is in the config, not in the app running inside
it. Because `draw_frame` is one function shared by every window, falling
back permanently (rather than per-window) also avoids re-logging the same
crash once per window per frame.

## B8 — A crashing keybinding took the whole process down, not just the app

**Symptom:** `wm:bind("super+x", function() error("boom") end)`, then
pressing the bound key, crashed `aster` outright instead of leaving the
desktop running — the same failure mode as B7, in a different call site.

**Cause:** `lua/aster/input.lua`'s `dispatch()` called a matched
keybinding's function directly (`fn()`), with no `pcall`. Every app callback
(`draw`/`key`/`text`/`tick`) already goes through `wm:guard`, and
`draw_frame` got its own `pcall` in B7 — but a keybinding registered via
`wm:bind` had no safety net at all. The error propagates out of
`dispatch()`, out of `aster.frame()`, and `src/main.zig` awaits that call
with `try`, so an uncaught Lua error there ends the whole process.

**Fix:** `dispatch()` now calls the matched keybinding under `pcall` and
logs on failure, without closing any window — a keybinding isn't attached
to one, unlike an app callback. Not routed through `wm:guard()` itself,
since that helper assumes a `win` to close.

## B9 — The external-edit watch could silently eat the first save

**Symptom:** starting `aster`, then immediately saving `wm.lua` in an
external editor before the watch had run once, did nothing — the edit was
picked up only on a *second* save.

**Cause:** `lua/aster/loop.lua`'s watch set its own baseline mtime lazily,
from whatever `host.list` first reported (`aster.last_mtime =
aster.last_mtime or e.mtime`). If that first poll happened to run after the
file had already been edited, the edited mtime became the baseline itself,
so the very edit that should have triggered a reload instead became "no
change since baseline."

**Fix:** the baseline is now primed once, in `aster.boot()`, from the mtime
as it stood right after the initial config load (`loop.lua`'s
`config_mtime()`, shared by `boot()` and the poll in `frame()`). Any edit
made after that point — including one that lands before `frame()` has run
even once — has a real prior value to compare against.

## B10 — "running built-in defaults" didn't always mean it

**Symptom:** when a config's replacement crashed AND rolling back to the
last known-good source also failed, the error bubble said "config rollback
failed, running built-in defaults" — but the wm singleton wasn't
necessarily reset to the built-in theme/keybindings at all.

**Cause:** `lua/aster/init.lua`'s reload protocol only called
`builtin_default()` in that branch `if not M.state.wm`. Since
`aster.wm.adopt()` mutates the singleton in place, `M.state.wm` is almost
always already set by the time this branch runs — including by the failed
config itself, partway through, before it crashed — so the fallback the
message promised usually never ran, and whatever half-reset state the
crashing chunk left behind kept running instead.

**Fix:** call `builtin_default()` unconditionally in this branch. It's
idempotent (`adopt()` returns the existing singleton; `wm:open` only fires
when there are no windows yet), so this can't lose open windows — it just
makes the safety net ADR-003 promises actually run every time.

## B11 — A long error message overran the error bubble off-screen

**Symptom:** a config error whose message was long (a deep stack line, a
long path, or just a long single token with no spaces) produced a bubble
wider than the screen, drawn starting at a negative x — mostly off the left
edge instead of the fixed-size box `ASTER-WM.md` §6.6 shows.

**Cause:** `lua/aster/wm.lua`'s `render_error_bubble` sized the box to
whatever `text_width` returned for the raw message, with no upper bound.

**Fix:** `wrap_line()` greedily wraps each bubble line to a fixed max width
(`BUBBLE_MAX_WIDTH`), hard-splitting by character the rare single token
that's wider than the max width on its own (no space to break on); the
total line count is capped at `BUBBLE_MAX_LINES`, with the overflow
collapsed to a single `"..."` line rather than growing the box further.
