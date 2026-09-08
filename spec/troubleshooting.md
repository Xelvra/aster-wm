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
accepting synthetic input. ADR-009 additionally moves the sdl backend off SDL2
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
edge instead of a fixed-size box.

**Cause:** `lua/aster/wm.lua`'s `render_error_bubble` sized the box to
whatever `text_width` returned for the raw message, with no upper bound.

**Fix:** `wrap_line()` greedily wraps each bubble line to a fixed max width
(`BUBBLE_MAX_WIDTH`), hard-splitting by character the rare single token
that's wider than the max width on its own (no space to break on); the
total line count is capped at `BUBBLE_MAX_LINES`, with the overflow
collapsed to a single `"..."` line rather than growing the box further.

## B12 — `@embedFile("../../assets/font.ttf")` failed to compile from `src/render/`

**Symptom:** `zig build` failed with `embed of file outside package path` for
`src/render/font.zig`'s `@embedFile("../../assets/font.ttf")`, even though the relative
path is textually correct (`src/render/` → `src/` → repo root → `assets/font.ttf`).

**Cause:** Zig resolves `@embedFile` (and `@import`) against the *root module's own
directory* and refuses to climb back out above it — that boundary was `src/`, because
`build.zig`'s three targets all pointed `root_source_file` at `src/main.zig`. `assets/`
sits next to `src/`, one level above that boundary, so no relative path from any file
under `src/` could ever reach it.

**Fix:** rather than moving the module boundary (tried first: a repo-root shim
re-exporting `src/main.zig` — worked, but relocates the project's actual entry point just
to satisfy one embed), added `assets/font.zig` — a one-line module (`pub const bytes =
@embedFile("font.ttf");`) rooted at `assets/` itself, so the embed has no boundary to
cross. `build.zig` builds it as its own module (`b.createModule`) and gives each of the
three targets an import (`addImport("embedded_font", font_mod)`); `font.zig` reads
`@import("embedded_font").bytes` instead of embedding the file directly. `src/main.zig`
stays the real, unmoved entry point.

## B13 — The glyph cache leaked every rasterized glyph at shutdown

**Symptom:** running `aster` to a clean exit (not killed by `timeout`) printed a
`DebugAllocator` leak report for every cached glyph bitmap, plus the cache's own hash map
and LRU list.

**Cause:** `src/render/font.zig`'s glyph cache is a module-level global, deliberately kept
alive for the process's lifetime (ADR-006: rasterize once, not per frame) — but nothing
ever freed it. `main.zig` already pairs every other subsystem's `init` with a `defer
...deinit()` (`sdl_backend.Sdl`, `lua.State`); the font cache had the `init` half
(`renderer.initFont`, wired at boot) without the matching `deinit`.

**Fix:** added `font.deinit()` (frees every cached bitmap, then the cache and LRU
containers themselves) and `renderer.deinitFont()` forwarding to it, called via `defer`
right after `renderer.initFont()` in `main.zig` — the same pattern as the two subsystems
next to it.

## B14 — A `host.read` failure other than "not_found" could crash the whole process

**Symptom:** if `~/.config/aster/wm.lua` existed but couldn't be read (wrong permissions, or
the path is a directory) on the very first boot, `aster` crashed outright instead of falling
back to the built-in default — the one thing ADR-003 says must never happen.

**Cause:** `lua/aster/init.lua`'s `M.reload()` only called `builtin_default()` when
`M.state.wm` was nil in the `err == "not_found"` branch. Every other read error
(`"permission"`, `"io"`, `"busy"`, `"invalid"`) fell into an `else` that just logged and
returned, leaving `M.state.wm` as whatever it already was — `nil` on a first boot. The next
`aster.frame()` call (`loop.lua`) guards `wm:tick()` with `if aster.state.wm then` but calls
`aster.state.wm:render(...)` unconditionally, so indexing `nil` took the whole process down.
Not caught by any test: `tests/ui/fakehost.lua`'s `read()` could only ever simulate
`"not_found"`.

**Fix:** the non-`"not_found"` branch now mirrors the compile/runtime-error branches
exactly: `builtin_default()` (unconditionally, same reasoning as B10) plus an error bubble
when there's no previous config to fall back to, or just an error bubble naming the error
when there is. `fake._set_read_error(path, err)` added to `fakehost.lua` so this path is
actually exercisable; `tests/ui/reload_read_error.lua` covers first-boot and later-reload
read failures.

## B15 — `host.clock()`'s fallibility was declared in the contract but unimplementable

**Symptom:** none yet observed at runtime — found by inspection, not a crash — but
`spec/host-contract.md`'s "the two must agree" requirement between `host.clock()` returning
`nil, "unsupported"` and `info().caps.clock = false` had no way to ever hold for a real
backend.

**Cause:** `src/host/fs.zig`'s `clock()` was shared, infallible (`pub fn clock() host.Clock`,
no error union) code used by every backend, per the file's own header comment ("Filesystem,
clock and log: identical on every backend"). `src/host/bindings.zig`'s `lClock` had no path
to `nil, err` either. Only `tests/ui/fakehost.lua`'s fake and `spec/conformance/05_time.lua`
implemented the capability-gated contract correctly; against the real binary, `caps.clock`
is hardcoded `true` in the only backend that exists, so the "unsupported" branch was
structurally dead code, not just untested.

**Fix:** moved the clock decision into the backend vtable (`host.zig`'s `Backend.clockFn`,
returning `?Clock`), alongside `info`/`surface`/`present`/`wait` — the same shape ADR-008
already uses for `caps.spawn`. `fs.zig` keeps the actual wall-clock read as a plain helper
(`realClock()`) that any backend with a real clock can call from its own `clockFn`; a future
backend with none returns `null` from its own instead. `bindings.zig`'s `lClock` now calls
`active_backend.clock()` and returns `nil, "unsupported"` when it's `null`.

## B16 — A config that compiled clean but never called `adopt()` still passed reload's verify step, on the very first boot only

**Symptom:** `: > $HOME/.config/aster/wm.lua` (an empty file — the simplest
case of "compiles but never adopts"), then starting `aster`, crashed with
`lua/aster/loop.lua:56: attempt to index a nil value (field 'wm')` instead
of falling back to the built-in default.

**Cause:** `lua/aster/init.lua`'s reload verify step checked
`result ~= M.state.wm` to decide whether a config actually called
`aster.wm.adopt()`. On the very first boot `M.state.wm` is itself `nil`, so
a config that compiles and runs without error but never calls `adopt()`
(and so returns nothing) satisfied `nil ~= nil` as `false` — verification
passed, `M.state.config_src` was saved as "last known good", and
`M.state.wm` was left `nil`. `loop.lua`'s `M.frame()` guards
`aster.state.wm:tick(...)` with `if aster.state.wm then` but called
`aster.state.wm:render(...)` unconditionally two lines below, so the very
next frame indexed `nil`.

**Fix:** the verify condition is now `result == nil or result ~= M.state.wm`,
so a config returning nothing always fails verification, first boot
included. `loop.lua`'s `render` call is now guarded the same way `tick` is,
so a future third path into the same nil-`wm` state fails safe instead of
crashing. `tests/ui/reload_verify_no_adopt.lua` covers the first-boot case.

## B17 — An app passing a bad argument to `__native_render` crashed the whole process, not just its own window

**Symptom:** an app calling `aster.render.fill_rect(surface, x, y, -1, h, color)`
(a negative width — an easy off-by-one) crashed `aster` with `thread ...
panic: integer does not fit in destination type` at `bindings.zig`'s
`nFillRect`; an app calling `draw(win)` and forgetting the `surface`
parameter crashed with `panic: cast causes pointer to be null` in
`surfaceArg`. Neither was catchable by `wm:guard`, unlike every other app
callback error.

**Cause:** all twelve `n*` `__native_render` functions in
`src/host/bindings.zig` converted Lua numbers straight from
`luaL_checkinteger` through `@intCast` into `i32`/`u32` with no range
check, and `surfaceArg` cast `lua_touserdata`'s result with no type check
at all. A Zig panic unwinds the process, not the Lua stack — `pcall`
(and so `wm:guard`) has nothing to catch. In a `ReleaseFast` build, where
safety checks are compiled out, the same inputs don't even panic: a
negative width becomes a multi-billion-pixel fill loop, and a missing
surface becomes a write through a null pointer.

**Fix:** `checkI32`/`checkU32` validate the integer's range before casting
and raise via `luaL_argerror` on failure — a real Lua error that `pcall`
catches, so `wm:guard` closes just the offending app's window.
`surfaceArg` now checks `lua_type(L, idx) == LUA_TLIGHTUSERDATA` before
casting, same mechanism. `__native_render` is the one boundary where "no
defensive code against inputs that can't occur" (`spec/code-style.md`)
does not apply, because unlike every other `host.*`/`aster.*` call it is
reachable directly from arbitrary app Lua, not only from Zig calling Zig.

## B18 — A window resize never marked the frame dirty

**Symptom:** under a backend where a resize event isn't accompanied by
mouse movement, the window stayed blank (the old surface's contents, or
uninitialized memory) until some unrelated input arrived. Under SDL this
was mostly hidden because dragging a window's corner also generates
`mouse_move` events, which do mark the frame dirty.

**Cause:** `lua/aster/loop.lua`'s `M.frame()` refreshed `aster.info` on a
`resize` event but never called `aster.mark_dirty()`, and
`lua/aster/input.lua`'s `dispatch()` has no branch for `"resize"` either.
The backend hands over a freshly (re)allocated, blank surface on resize
(ADR-005's "cheapest possible" redraw skip assumes `dirty` gets set
whenever the frame actually needs repainting) — resize is the one event
after which a redraw is not optional.

**Fix:** `M.frame()` now calls `aster.mark_dirty()` in the same branch that
refreshes `aster.info`.

## B20 — A unit test calling `std.debug.print` intermittently corrupted `zig build test`'s own test-server protocol

**Symptom:** a new, otherwise-correct unit test that triggered `fs.log()`
(`std.debug.print` to stderr) during its run made `zig build test` fail
with `thread ... panic: internal test runner failure: EndOfStream`, no
per-test PASS/FAIL output at all — while running the exact same compiled
test binary directly (without the build system's `--listen=-` protocol)
passed all tests cleanly, including the one doing the printing.

**Cause:** `zig build test` drives the compiled test binary over a small
binary protocol on stdin/stdout (`--listen=-`) to get structured per-test
results back. On this machine's Zig 0.16.0, a test that writes to stderr
via `std.debug.print` while that protocol is live intermittently (not
every run) desyncs it, and the build driver's next read of a message
header hits `EndOfStream` instead of an error report for the actual test.
This is specific to the `--listen=-` server path — running the test binary
plainly is unaffected — and is a toolchain quirk, not a bug in the code
under test.

**Fix:** don't call `fs.log`/`std.debug.print` (or anything else that
writes to stderr) from inside a `zig build test`-run unit test. Where a
test needs to cover a code path that logs in production (e.g. the bitmap
font fallback logging why it engaged), test the underlying condition that
would trigger the log (e.g. `ttf.load` returning an error) instead of
going through the function that actually calls the logger, and verify the
logging side effect separately by running the real binary. No workaround
was found that keeps the log call inside the automated suite; this may be
worth re-testing on a future Zig release.

## B21 — `gradient_border`'s `thickness` argument drew the same single-pixel outline regardless of its value

**Symptom:** `aster.render.gradient_border(s, x, y, w, h, thickness, a, b)`
drew visually identical output for every `thickness` greater than zero —
the argument existed in the signature but changing it did nothing.

**Cause:** the gradient outline itself (`gradientOutline`, used by
`rectBorder`'s solid-color sibling too) only ever draws a one-pixel-wide
line; nothing repeated that line inward to make a border actually
`thickness` pixels wide.

**Fix:** `gradientBorder` now nests the single-pixel outline inward,
`thickness` times, shrinking `w`/`h` by two pixels on each pass — the loop
also stops once nesting further would invert the rectangle
(`w > 2*t and h > 2*t`), so a `thickness` larger than half the shape's
smallest dimension degrades gracefully instead of drawing garbage.

## B22 — The error bubble's hard-split path measured text quadratically and could split a UTF-8 sequence in half

**Symptom:** none observed at runtime under normal message lengths — found
by inspection. `lua/aster/wm.lua`'s `wrap_line`, used to hard-split a
single word too wide to fit the error bubble on its own, would (1) become
quadratic in the word's length for a single very long token, since its
inner loop re-measured `r.text_width` on the whole accumulated prefix on
every single byte advance, and (2) slice `word:sub(1, i)` at a raw byte
offset, which for a message containing non-ASCII text could land in the
middle of a multi-byte UTF-8 sequence and draw as U+FFFD.

**Cause:** the loop grew `i` one byte at a time and called
`r.text_width(word:sub(1, i))` at each step to re-check the fit, rather
than accumulating width incrementally; and `#word`/`word:sub` operate on
bytes, with no codepoint awareness.

**Fix:** the hard-split loop now walks `word` one UTF-8 codepoint at a time
(`each_codepoint`), summing each codepoint's own width once instead of
re-measuring the whole prefix, and only ever cuts on a codepoint boundary.

## B23 — Zig's default UBSan instrumentation traps inside `lua_newstate` on wasm32-freestanding, but only there

**Symptom:** `aster-wasm`'s `lua_newstate()` trapped with `RuntimeError:
unreachable` inside `ubsan_rt.typeMismatch`, every time, on the very first
call — before any of this project's own code ran. The identical Lua
source, compiled for the native `sdl`/`aster-conformance` targets with the
same `zig cc`-driven build, never hits this.

**Cause:** Zig's C compilation adds a broad default `-fsanitize=...` set
(alignment, null, nonnull-attribute, ...) unless told otherwise. Lua
5.4's `lua_State`/`GCObject` machinery relies on pointer-punning tricks
that are technically UB-adjacent but universally relied upon in practice
on every platform Lua actually ships on — something about wasm32's
pointer/alignment representation makes one of those checks fire where the
same code on a native target's ABI doesn't.

**Fix:** `build.zig`'s `wasm_c_flags` passes `-fno-sanitize=all` for the
wasm backend's C sources specifically (Lua + `vendor/rt.c`), not applied
to the native `sdl` build. Confirmed this isn't papering over an actual
bug, not just assumed: behavior after disabling the trap is exactly
correct (spec/adr/013's Node.js harness — real `aster_boot`/`aster_frame`
calls against the real `lua/aster/*` core, not a synthetic test).

## B24 — `libc.zig`'s exports were silently dropped from the wasm build, and the linker didn't say so

**Symptom:** the very first `zig build` wiring the wasm backend into
`build.zig` reported success — zero errors — but `WebAssembly.Module.exports()`
on the resulting `.wasm` showed only `memory`, none of `aster_init`/
`aster_boot`/.../`malloc`/`strcmp`/etc. Setting `exe.rdynamic = true` (to
make the `aster_*` entry points actually appear in the export table)
turned the same build into over a hundred `undefined symbol` errors for
things like `time`, `strcmp`, `snprintf` — symbols `libc.zig` genuinely
defines.

**Cause:** nothing in `src/main_wasm.zig` ever referenced
`src/backends/wasm/libc.zig` by name — Zig only analyzes and emits a
file's declarations if something reachable from the root module imports
it, `export fn` or not. Without `rdynamic`, wasm-ld apparently tolerated
the resulting undefined symbols by turning them into bogus
zero-returning imports instead of failing the link — the same silent
"wrong instead of missing" failure mode ADR-013's own investigation hit
earlier with a hand-rolled `wasm-ld --allow-undefined` invocation, this
time from `zig build-exe`'s own default behavior.

**Fix:** `main_wasm.zig` has a `comptime { _ = @import("backends/wasm/libc.zig"); }`
block specifically to force the analysis. Generalizable lesson: on this
target, "the build succeeded" and "the exports/imports are the ones you
expect" are two separate claims — check `WebAssembly.Module.imports()`/
`.exports()` on the actual output before trusting a clean build, the same
way ADR-009's SDL2→SDL3 migration learned not to trust "it compiled" for
a native backend either.

## B25 — `host.list()` returned entry names with a leading `/`, and `host.remove()` on a directory silently did nothing

**Symptom:** `spec/conformance/06_fs.lua` failed on the wasm backend only:
`list must include the file just written`, even though the file had
genuinely been written and `host.read()` on its exact path succeeded.

**Cause:** `fs_wasm.zig`'s `list()`/`remove()` forward the raw directory
path to JS unchanged; the JS side (both `glue.js` and
`tools/wasm-conformance.js`) matched storage keys with a plain
`key.startsWith(path)` and then returned `key.slice(path.length)` as the
entry name. For a stored key `"<dir>/round-trip.txt"` and `path ==
"<dir>"` (no trailing slash — host.info().paths never has one), that
produces the entry name `"/round-trip.txt"`, not `"round-trip.txt"` —
`fs_native.zig`'s real directory iteration never has this problem since
`std.Io.Dir.iterate()` already returns bare names. Separately,
`host.remove()` only ever deleted a key matching the path *exactly*,
never anything nested under it as a prefix — a no-op on every call in the
test, which never stores anything at the bare directory path itself.

**Fix:** both JS files now match `key.startsWith(path + "/")` and slice
off `path.length + 1`, and `remove()` deletes the exact-match key *and*
every key nested under `path + "/"`, succeeding if either found
something — matching `fs_native.zig`'s `deleteTree`, which is recursive
by construction.

## B26 — `Module.addEmbedPath` doesn't reliably reach an `@embedFile` call once the calling file is part of a circular import

**Symptom:** tried replacing `lua_embed.zig`/`conformance_embed.zig` (two
sibling-module files at the repo root, ADR-006's font.zig trick) with
`std.Build.Module.addEmbedPath` — a real Zig 0.16 API built for exactly
this: letting `@embedFile` reach outside a module's own root directory
without a helper file. `src/backends/wasm/modules.zig`'s
`@embedFile("aster/init.lua")` failed with `FileNotFound` even though
`wasm_mod.addEmbedPath(b.path("lua"))` was set and the CLI invocation
genuinely carried `--embed-dir=.../lua`.

**Investigation:** isolated reproductions (a fake root importing a copy
of `modules.zig`, with or without the real C-source compilation, with
or without `-rdynamic`, with 1-3 embed-dirs) all **worked** — the
mechanism itself is sound. It only failed once the *real*
`src/host/lua.zig` was in the import graph and `lua.State.init()` was
actually called (not just referenced as a value) — `lua.zig` and
`src/host/bindings.zig` import each other (`lua.zig`'s `bindings =
@import("bindings.zig")`, `bindings.zig`'s `lua = @import("lua.zig")`),
and `modules.zig` also imports `lua.zig` for its `c` (lua.h) namespace.
Root cause not fully isolated — likely an interaction between this
circular pair and Zig's embed-path-to-module association — but the
trigger condition is real and reproducible on demand: a plain synthetic
circular-import pair (no Lua, no C sources) did *not* reproduce it, so
it's specific to this codebase's actual shape, not circular imports in
general.

**Fix:** reverted to the sibling-module-file approach (kept
`lua_embed.zig`/`conformance_embed.zig` at the repo root) rather than
spend more time on a from-scratch Zig bug report mid-milestone.
`addEmbedPath` remains the technically-correct tool for this and is
worth retrying on a future Zig release, or once the circular
`lua.zig`/`bindings.zig` import is broken up for its own sake — but
don't reach for it here again without re-verifying against the real
import graph first, not just a synthetic reproduction.

**Resolved, and the cause above is wrong.** `addEmbedPath` is not
unreliable here: on this Zig 0.16.0 it does nothing for `@embedFile` at
all. A two-line `main.zig` with no Lua, no C sources and no circular
imports fails identically under a bare `zig build-exe
--embed-dir=<dir> -Mroot=src/main.zig`, with the flag before or after
`-M`, with an absolute or relative dir, and for every spelling of the
embedded path. The flag is accepted and forwarded; `@embedFile`'s search
never consults it.

The earlier reproductions "worked" because they never embedded anything:
container-level decls are analyzed lazily, so a `pub const x =
@embedFile(...)` nothing references never opens the file. The apparent
trigger condition — the real `lua.zig` in the graph and
`lua.State.init()` actually called — was only the first code path that
forced the decls to be analyzed at all (`init` → `modules.register`).
**A reproduction of a compile-time builtin proves nothing unless the
result is referenced from code that is actually analyzed.**

The working mechanism is a mapped module, not an embed path:
`@embedFile` resolves module names the same way `@import` does
(ziglang/zig#14553), so build.zig maps each embedded `.lua` file with
`Module.addAnonymousImport` under its repo-relative name
(`"lua/aster/init.lua"`) and the call sites `@embedFile` that name. It
crosses the module boundary with no helper file, so both root-level
`lua_embed.zig`/`conformance_embed.zig` are gone and the repo root is
back to directories and conventional files.

## B27 — `src/backends/wasm/`'s unit tests never ran, and three real bugs were hiding behind that

**Symptom:** none, which was the problem. `src/backends/wasm/libc.zig` carried two `test`
blocks that had never executed: `zig build test` builds its unit-test binary from
`src/main.zig`'s module, and nothing in that import graph reaches the wasm-only files
(`src/host/lua.zig` pulls in `modules.zig` only under `if (comptime ...isWasm())`, and
`libc.zig` hangs off `main_wasm.zig`). Proven by making one of those tests fail on purpose:
`zig build test` stayed green.

**Cause of the gap:** a wasm test binary can't just be added next to the native one. Two
things block the obvious attempts, both verified before settling on the shape below:

- `std.testing` does not compile for `wasm32-freestanding` on this toolchain — it reaches
  `std.Io.Threaded`, which reaches `posix` (`getrandom`, `IOV_MAX`). Tests that run on this
  target need their own tiny `expect` helpers. A plain `return error.TestFailed` is fine.
- Zig's default test runner needs stdout and the same `Io`, so the build passes
  `tools/wasm-test-runner.zig` (`.mode = .simple`) instead: it exports the test count, a
  `run` entry point, and the names that failed, and `tools/wasm-tests.js` reads them back.

The test module is rooted at `libc.zig`, not `main_wasm.zig`, because a test build compiles
the test blocks of *every* file in the root's import graph — and `main_wasm.zig` reaches
`src/render/`, whose tests use `std.testing` correctly, since the native binary is where
those run.

**Bugs found once the tests actually ran** (all three failed on the real target, all three
now covered):

1. `%d` with a plain `int` read the vararg as `long long`. `vsnprintfImpl` skipped the length
   modifier and always read `c_longlong`, on the belief that lstrlib.c's `addlenmod` always
   inserts `"ll"` — it doesn't for the formats lstrlib.c writes by hand:
   `string.format("%q", s)` escapes a control character with `"\%d"`/`"\%03d"` and
   num2straux appends `"p%+d"`, all with an `int`. On wasm32 varargs live in a memory buffer,
   so reading eight bytes where four were written reads past the argument. **This is the
   class of bug a native test cannot see** — on x86-64 the same code passes.
2. `%G` never stripped trailing zeros (`1.00000E+15` instead of `1E+15`).
   `printfStripTrailingZerosExp` searched for `'e'`, but the uppercase path had already
   written `'E'`, so it returned the string untouched.
3. `%#g` dropped the trailing decimal point (`100000` instead of `100000.`). The `.f` branch
   appended it for `alt and precision == 0`; the `.g` branch didn't.

**A fourth cause, since resolved:** `std.fmt.float.render` rounds the *shortest* decimal
representation rather than the exact binary value, so fixed-precision output differed from C
in the last digit — `%.2f` of 1.005 gave `1.01` where C gives `1.00` (1.005 is really
1.00499999999999989342), `%.0f` of 0.5 gave `1` where C gives `0`, `%f` of 1e100 printed
zeros instead of the true expansion, and subnormals printed as `5e-324` instead of
`4.94066e-324`. Measured against glibc over 399 conversions: 27 differed before the three
fixes above, 21 after, and every one of those 21 was this. `tostring()` (`"%.14g"`) was never
affected — 14 significant digits sit inside the shortest round-trip form.

`libc.zig` now converts exactly instead (ADR-014): a double is `m × 2^e`, and
`m / 2^k = m × 5^k / 10^k`, so the exact digits come from multiplying a decimal digit array
by 2 or by 5 — no division, no binary bignum. Rounding is to nearest with exact ties to
even. Verified differentially against glibc over 12,029 doubles × 10 format specifiers, with
one deliberate difference recorded in ADR-014: `%#g` of 999999.5, where glibc contradicts
itself and drops digits `#` is defined to keep.


## B28 — the browser's `host.write`/`host.read` lost every byte that wasn't valid UTF-8, and the conformance suite couldn't see it

**Symptom:** none from the suite, which is the interesting half. `spec/conformance/06_fs.lua`
round-tripped `"hello"` and passed on both backends, while the wasm backend running in a
browser turned a six-byte file containing `0xff 0xfe 0x00` into a ten-byte one.

**Cause:** `src/backends/wasm/glue.js` stored file contents as decoded text —
`TextDecoder` on the way in, `TextEncoder` on the way out — so every byte that isn't valid
UTF-8 became U+FFFD (three bytes) on the way back. A Lua string is bytes, not text
(`spec/host-contract.md`), and `wm.lua` is only ASCII until someone pastes something into
it.

**Why the suite couldn't catch it:** `tools/wasm-conformance.js` implemented the same
eleven `aster` imports a second time, over Node `Buffer`s, which are byte-exact by
construction. What the suite certified was never the code the browser runs — the same
duplication B25 had already shown up as one bug that had to be fixed in two files.

**Fix:** `glue.js` now owns `hostImports(env)`, and everything that differs between a tab
and the test runner (where linear memory is, where files live, what `present` and `log` do)
arrives in `env`. `tools/wasm-conformance.js` requires that file and installs a
`localStorage` stand-in — a Map of strings, which is what Web Storage is — rather than
handing glue.js a friendlier byte-keyed store of its own: the encoding a store does on the
way in and out is exactly where this bug lived, so the suite has to run the browser's store,
not a substitute for it. Contents cross as one code unit per byte (0-255), which localStorage
keeps unchanged (verified in Chrome, not just in Node).

`06_fs.lua` now writes `"b\xff\xfe\x00\x01ytes"` and requires it back byte for byte.
That assertion was checked both ways before being believed: against the old text-decoding
store it fails ("wrote 9 bytes, read back 13"), against the fix it passes, and SDL passes
either way since it was never the backend with the problem.


## B29 — the browser never called `aster.shutdown()`, and `aster_push_quit` had no caller

**Symptom:** none the conformance suite could see — `spec/host-contract.md` says `"quit"`
from `frame()` "means stop calling `frame` and call `shutdown`", and `src/main.zig` holds
that on every other backend via a `defer` around the SDL main loop. `docs/demo/index.html`
called `load/init/attachInput/boot/run` and nothing else; `glue.js`'s `run()` tick, on seeing
`frame() === "quit"`, just returned. `aster_push_quit` was exported from `main_wasm.zig` (the
wasm analog of `SDL_EVENT_QUIT`) but `Aster` had no method wrapping it — confirmed by diffing
the wasm binary's exports against `glue.js`'s calls, nothing else exercises it.

**Why it matters:** a real tab close is a `beforeunload` event, not a `frame()` return value
— there's no guarantee another `requestAnimationFrame` callback ever runs after it fires, so
waiting for the next tick to notice a queued quit event is not safe to rely on there.

**Fix:** `Aster.pushQuit()` now wraps the export; `run()`'s tick calls `this.shutdown()`
before returning when `frame()` reports `"quit"` (the keybinding-driven path, verified by
pushing a quit event into a running loop and observing both calls fire); and
`attachInput` adds a `beforeunload` listener that pushes the quit event and drains it with
one direct `frame()` call rather than waiting on the RAF loop, calling `shutdown()` itself if
that returns `"quit"` — verified in Chrome by dispatching the event manually and watching
`pushQuit()`/`shutdown()` log in order.

**Fixed alongside, same file:** `mousedown`/`mouseup` passed `attachInput`'s fractional
`clientX/clientY - rect` straight to `pushMouseDown`/`pushMouseUp`, which truncate towards
zero (`x | 0`) on the wasm side; `mousemove` already rounded before pushing. A click and a
move at the same physical pixel could therefore report adjacent coordinates. Both handlers
now round the same way `mousemove` does, before the value crosses into wasm.


## B30 — `runScript` and `aster_run_conformance` duplicated the same pcall/skip/error logic, and it had already drifted

**Symptom:** `src/host/lua.zig`'s `runScript` (every non-wasm backend, loading a file via
`luaL_loadfilex`) and `main_wasm.zig`'s `aster_run_conformance` (no filesystem on that
backend, so it loads an `@embedFile`'d buffer via `luaL_loadbufferx` instead) each reimplemented
the same `lua_pcallk` → check for a `"SKIP:"`-prefixed error → report as skip (exit 2), report
as failure (exit 1) otherwise. They had already diverged: `runScript` printed the skip message
with `std.debug.print`, `aster_run_conformance` with `fs.log` — and `reportError`'s own comment
a few lines above `runScript` said `std.debug.print` was "the wrong tool here regardless of
backend", contradicted by the code right below it.

**Why it's the same class as B25/B28:** two independent implementations of one contract path,
kept in step by hand instead of by the compiler. It's a smaller instance of the exact pattern
`glue.js`/`tools/wasm-conformance.js` and the browser/Node `aster` imports already were —
nothing here reached across the wasm boundary, but the lesson (don't let a second copy of
host-facing control flow exist to drift) is the same one.

**Fix:** the pcall/skip/error handling was pulled into `State.runLoaded`, which both callers
invoke on the function each already loaded onto the stack by its own means. Both now go
through `fs.log` for a declared skip, matching `reportError`, so the comment above it is true
again. Re-verified clean: `wasm-tests` 8/8, `tests/ui` 22/22, conformance (sdl) 7/7,
wasm-conformance 7/7.
