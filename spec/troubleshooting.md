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
