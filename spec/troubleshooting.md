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

## B19 — The glyph cache reordered an `ArrayList` on every lookup, and a cache hit's pointer could be invalidated by the caller's own next call

**Symptom:** none observable yet — found by review, not by a failing test or
a user report. `src/render/font.zig` cited this id from five call sites
before the entry existed (M6 review finding B-c), which is itself the bug
this rule exists to catch: `spec/code-style.md`'s "a comment may cite an
incident by id, never restate it" only works if the id resolves to
something.

**Cause:** two separate problems in the original glyph cache.

1. LRU eviction was tracked by keeping the cache in an `ArrayList` ordered
   by recency and moving an entry to the front on every `glyph()` call,
   even on a cache hit. That is an O(n) shuffle on the hot path of drawing
   every single character, for a hit rate that should make eviction rare.
2. The lookup path considered returning `cache.getPtr(codepoint)` directly
   to the caller. `std.AutoHashMapUnmanaged.put` (called on a miss, to
   insert the freshly rasterized glyph) can trigger a rehash, which
   invalidates any pointer obtained from an earlier `getPtr` — a pointer
   handed to one caller could go stale the moment a *different* codepoint
   was rasterized afterward.

**Fix:** replace the ArrayList-ordered cache with a plain
`AutoHashMapUnmanaged` keyed by codepoint, where each `CachedGlyph` carries
its own `last_used` stamp from a monotonic `use_clock` bumped once per
`glyph()` call. Eviction (`evictLru`) scans the whole map for the lowest
stamp, but only runs when the cache is actually at `max_cached_glyphs` —
at most once per `max_cached_glyphs` new codepoints, not once per lookup.
`glyph()` returns `CachedGlyph` by value (a copy), never a pointer into the
map, so a later `put`'s rehash can't invalidate anything the caller is
still holding.

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

## B31 — `host.wait` with an out-of-range timeout panicked the whole process instead of erroring

**Symptom:** any app calling `host.wait(2^40)` (or any value outside i32
range) took the entire process down with a Zig panic, not a catchable Lua
error:

```
thread NNNNN panic: integer does not fit in destination type
src/host/bindings.zig:247:26: in lWait
    const timeout: i32 = @intCast(c.luaL_optinteger(st, 1, 0));
```

**Cause:** `spec/code-style.md`'s "no defensive code" rule was written to
cover `host.*` alongside `aster.*`, on the reasoning that both are a closed
contract. That reasoning is wrong for `host.*`: `aster.boot`/`frame`/
`shutdown` are called only by the host driver (Zig calling Zig), but `host`
is a global table reachable from any app's Lua exactly like
`__native_render` is (B17) — "an input that can't occur" doesn't hold for
either. `lWait` was the one `host.*` binding still doing the unchecked
`@intCast(luaL_checkinteger(...))`/`@intCast(luaL_optinteger(...))` pattern
B17 had already fixed for `__native_render` via `checkI32`/`checkU32`.

**Fix:** added `optI32` (the `luaL_optinteger` counterpart of `checkI32`,
for arguments that may be absent) and used it in `lWait`; an out-of-range
timeout now becomes `luaL_argerror`, catchable by `pcall`. `spec/code-style.md`
corrected to scope "no defensive code" to `aster.*` only. Covered by
`spec/conformance/04_events.lua`, which is normative for `host.wait` across
every backend.

## B32 — An app could escape its clip rect, and `clipped`'s final `pop_clip` couldn't tell

**Symptom:** an app whose `draw` callback called `r.pop_clip(s)` (directly,
not through `r.clipped`) could paint outside the rectangle
`lua/aster/render.lua`'s `clipped` had just clipped it to:

```
$ ./zig-out/bin/aster-conformance cliptest.lua
pixel outside the clip rect:	0xff0000
clip escape: CONFIRMED
```

This directly contradicted two places that claimed otherwise:
`apps/hello-window.lua`'s tutorial comment ("Drawing is clipped to the
window, so you can't paint over your neighbours even if you try") and
`spec/architecture.md`'s rule 3 ("a buggy app can't paint over its
neighbours"). Not a security issue (aster has no security boundary and
won't get one — an app is code, not sandboxed data) — a false claim in the
tutorial every first contributor learns from.

**Cause:** `clipped` was `push_clip(s, ...); pcall(fn); pop_clip(s)`,
assuming `fn` never touches the clip stack itself. `r.pop_clip` is a raw
primitive exposed the same way to any app (nothing separates "inside a
`clipped` callback" from "holding a surface"), so a buggy or careless `fn`
calling it early pops `clipped`'s own pushed level out from under it. The
*surface's* clip immediately reverts (that part of the escape — `fn`
painting unclipped for the rest of its own call — isn't fully closeable
without the renderer learning what a window is, which rule 3 forbids). The
part this fixes is what happened next: `clipped`'s own trailing `pop_clip`
ran at the wrong depth. At top level that pop landed on depth 0, where
`Surface.popClip` is already a documented no-op — so the mismatch didn't
even surface as a Zig error, it just silently matched the pre-call state by
coincidence. Nested one level deeper (a `clipped` call inside another
window's own clip, the realistic case), the same trailing `pop_clip` popped
the *outer* window's clip level instead of restoring it, corrupting the
clip stack for every draw call after `clipped` returned — with no error,
no crash, and no test catching it.

**Fix:** `Surface` gained `clipDepth()` and `restoreClip(depth)`
(`src/render/surface.zig`), exposed as `__native_render.clip_depth`/
`restore_clip`. `clipped` now records `clip_depth(s)` before pushing and
calls `restore_clip(s, depth)` instead of a bare `pop_clip` — `restoreClip`
only ever pops down to the recorded depth (it can't fabricate a push `fn`
never made), so the surface's clip stack is always back to exactly what it
was before `clipped` was called, regardless of how many times `fn` pushed
or popped in between. Covered by `tests/ui/clipped_escape.lua` (fakehost
models clip depth the same way `Surface` does) and by new assertions in
`spec/conformance/02_surface.lua` against the real renderer, including the
nested-`clipped`-inside-another-clip case where the pre-fix bug was
permanent, not just transient.

## B33 — `Sdl.resize` took the whole desktop down if the new surface couldn't be allocated

**Symptom:** found by review (M6, finding B-d), not a live crash report.
`src/backends/sdl/backend.zig`'s `resize` destroyed the current
`pixel_surface` and then unwrapped `SDL_CreateSurface(...)` with `.?` — an
allocation failure at the new size (a resize to something absurdly large,
or just low memory) would hit the `.?` unreachable-on-null panic with the
old surface already destroyed. It was the one unhandled SDL call in the
file; every other fallible SDL call already had a check.

**Fix:** build the new surface first and only destroy the old one once the
new one exists. On allocation failure, log via `fs.log` and return, leaving
the previous surface (and its last rendered frame, at the old size) in
place — a resize that fails is not a reason the desktop should disappear.
No new automated test: reliably forcing `SDL_CreateSurface` to fail from
within `spec/conformance/07_resize.lua` isn't something the dummy SDL
driver can be made to do without stubbing `SDL_CreateSurface` itself, which
none of the conformance suite does for any other primitive.

## B34 — An app whose `tick` returns `true` every frame pinned a full core, and pacing alone didn't fix it

**Symptom:** an app whose `tick` callback unconditionally returns `true`
(any per-frame animation) marks every frame dirty, so `src/main.zig`'s loop
called `state.frame()` again immediately with nothing between one call and
the next — the "idle" branch's `sdl.idleWait(1000)` (B6) only runs when a
frame reports `"idle"`, never `"running"`:

```
$ ps -o pid,%cpu,etime,cmd -C aster
  34061 97.6  00:03 ./zig-out/bin/aster
```

**Cause, part 1:** no pacing existed for "running" frames at all — the loop
was unbounded, calling `state.frame()` as many times per second as the CPU
allowed.

**Cause, part 2 (found while verifying the fix by measurement, not just
capping the loop):** once frame rate was capped to ~60fps, CPU stayed far
higher than expected — measurement (temporary per-frame timing, removed
before the final commit) traced it to `renderer.zig`'s `fillRect`: a
full-screen background fill (`wm.lua`'s `M:render`, unconditional every
dirty frame) went through `Surface.setPixel` once per pixel — ~786,000
calls for a 1024x768 surface, each re-checking bounds and clip that
`fillRect`'s own upfront `s.clip.intersect(...)` had already resolved. That
alone cost ~6ms of a 16.67ms frame budget.

**Fix, part 1 — frame pacing (`src/main.zig`):** measure each frame's
duration (`fs.nowMs()` before/after `state.frame()`); if it finished under
the ~60fps budget (1000/60 ms), call `sdl.idleWait()` for the remainder
instead of looping immediately. `idleWait` is built on
`SDL_WaitEventTimeout`, so it still wakes up the instant real input
arrives — pacing adds no input latency, it only fills time a frame would
otherwise have spent spinning with nothing new to draw.

**Fix, part 2 — `fillRect` (`src/render/renderer.zig`):** write each
clipped row with one `@memset` instead of a per-pixel `setPixel` call.
Sound because `Surface.clip` is an invariant, not just this call's
argument: it starts as exactly the surface's own bounds
(`Surface.init`) and every `pushClip` only ever narrows it further via
`Rect.intersect`, so `s.clip.intersect(requested rect)` is already
guaranteed to fall inside both the requested clip *and* the surface's
pixel buffer — every per-pixel bounds check `setPixel` was doing had
already been decided once, up front, for the whole rect.

**Measured, same reproduction as the symptom above (app with `tick` always
returning `true`, drawing a full-window fill every frame,
`SDL_VIDEODRIVER=dummy`), `ps -o %cpu` after ~3s:**

| Build | Before (no pacing, original `setPixel`-based `fillRect`) | After (paced, `@memset`-based `fillRect`) |
|---|---|---|
| `zig build` (Debug, what `zig build test` and this repo's day-to-day loop use) | ~98% | ~45% |
| `zig build -Doptimize=ReleaseFast` (what a release binary ships) | not separately measured; unbounded looping saturates a core regardless of optimization level | ~15% |

Both numbers are a large drop from unbounded 100%-of-a-core spinning to a
CPU cost that scales with actual per-frame rendering work at a fixed
~60fps, not with how fast the CPU can loop — but the Debug number is not
down to a low single-digit percentage the way the ReleaseFast one nearly
is. The gap left after pacing is Debug-build overhead (bounds/safety-check
instrumentation Zig's Debug mode adds to every array access and arithmetic
op, on top of a 1024x768 full-screen redraw and an SDL present every single
frame) rather than an unbounded loop; a ReleaseFast build — what actually
ships — is already close to negligible. Further reduction (e.g. damage
tracking, so a frame with no visual change skips the redraw entirely —
deliberately out of scope per ADR-005) is future work.

## B35 — `__newindex` only intercepted the *first* `wm.theme = {...}` assignment, not every later one

**Symptom:** unifying theme defaults (D4) needed every `wm.theme = {...}`
assignment — `M.adopt`'s own initial one, and a config's separate one right
after — to fall back to a shared defaults table for any key it didn't set.
The first attempt gave `wm` a metatable with `__newindex` that, on seeing
key `"theme"`, wrapped the assigned table with
`setmetatable(v, { __index = M.default_theme })` and then `rawset(t, k,
v)`. It worked for the very first assignment and silently stopped working
for every one after:

```
bg=	nil
accent=	1118481
```

(`accent` correctly reflected the config's override; `background`, which
the config never set, came back `nil` instead of falling back to
`M.default_theme.background`.)

**Cause:** `__newindex` is a Lua metamethod that only fires when the key
being assigned does **not already exist** as a raw key on the table. `rawset`
inside the handler puts a real `"theme"` key on `wm` after the first call —
so `adopt()`'s own `wm.theme = opts.theme or {}` triggers the wrap once,
but a config's later `wm.theme = { accent = ... }` (a plain, ordinary field
assignment to an *already-existing* key) never reaches `__newindex` at all
and lands as an unwrapped plain table. This is exactly why the config's
theme table had no fallback: nothing was wrong with the wrapping logic
itself, `__newindex` just never ran a second time.

**Fix:** stop storing `theme` as a real field on `wm` at all. It lives in a
private, weak-keyed side table (`theme_storage`, keyed by the `wm` object)
instead, and both `__index` and `__newindex` are plain functions that
special-case `"theme"` explicitly rather than relying on `rawset` plus the
metatable's default lookup behavior. Since the key never becomes a raw
field on `wm`, every single assignment — first or hundredth — goes through
`__newindex` and gets wrapped. Caught by `tests/ui/reload_resets_theme.lua`
(already existing, updated for D4's "resets to default, not nil") and
`tests/ui/reload_rollback_failure.lua`, both of which read a theme key the
active config's `wm.theme = {...}` line never set.

## B36 — `require()` as the last item in a table constructor spread its second return value into the table too

**Symptom:** found running the real binary (not caught by `tests/ui/`,
which drives `lua/aster/bar.lua` through `fakehost.lua`'s stand-in
`require`, not the real embedded searcher's):

```
aster: bar widget crashed: attempt to call a nil value
```

Only the clock widget — the last one in `config/wm.lua`'s `widgets =
{...}` list — misbehaved; the workspace widget right before it worked
fine. `wm.bar.widgets` turned out to have **three** entries, not two:

```
key=	1	val=	table: 0x21c4fb10
key=	2	val=	table: 0x21c51d50
key=	3	val=	./apps/clock-widget.lua
```

**Cause:** Lua's `require(name)` returns **two** values —
`package.loaded[name]` and the second value the module's searcher
returned (for the Lua/file searcher, that's the path it loaded from; for
`src/host/modules.zig`'s embedded searcher, the `@embedded` chunk name).
`local x = require(...)` only keeps the first, but
`{ a, require("apps.clock-widget") }` is a table constructor, and Lua
spreads **all** of a call's return values into the table when that call
is the constructor's **last** element — exactly the position
`config/wm.lua`'s own `widgets = { require(...), require(...) }` put the
clock widget in. `widgets[3]` ended up being the loader's filename string,
not a widget. `Bar:render`'s `pcall(widget.draw, ...)` then tried to call
`("...").draw` — `nil`, since strings have no such method — caught by the
`pcall` (the bar kept rendering the other two widgets, and the process
never crashed: `wm:guard`'s isolation principle, applied here to widgets
too), but the clock widget silently never drew.

**Fix:** parenthesize a `require()` call that ends up last in a table
constructor — `(require("apps.clock-widget"))` — which truncates it to
one value, same as parenthesizing any other multi-value expression in
that position. `config/wm.lua`'s comment now flags the pattern at the
call site so the next widget added after it doesn't reintroduce this by
being the new "last" element with the same bug. Not specific to
`require`: any multi-return call in a table constructor's last position
has this behavior — `require` is just the one call this project's own
code uses in that position often enough to have hit it.

## B37 — the wasm demo's `<canvas>` could never receive typed text, only key presses

**Symptom:** found verifying the wasm demo in a real browser (not caught
by `spec/conformance/`, which drives events directly, or
`tools/wasm-conformance.js`, which never exercises `attachInput`'s DOM
listeners at all — both bypass the actual browser input path entirely).
Opening `apps/editor.lua` via Super+Z worked (a `key_down`), but nothing
typed ever appeared in the buffer: no error, no console message, `text`
events simply never arrived.

**Cause:** `src/backends/wasm/glue.js`'s `attachInput` listened for
`beforeinput` directly on the `<canvas>` element to capture typed
characters (`spec/keys.md`: `text`, not `key_down`, carries what was
actually typed). `beforeinput` is part of the InputEvent spec's editing-
host contract — it only fires on a real `<input>`/`<textarea>`/
`contenteditable` element. A `<canvas>` is never one of those, regardless
of `tabIndex` or focus state, and regardless of whether the keypress
comes from real hardware or synthetic automation — confirmed empirically
by attaching a `beforeinput` listener to the focused canvas and typing:
zero events, every time. Nothing before M6 needed this: `hello-window.lua`
only uses `key`, so the gap was latent since M5 and never noticed until
`apps/editor.lua` became the first thing that needed to actually type.

**Fix:** keyboard focus (and so `keydown`/`keyup`/`beforeinput`/`focus`/
`blur`) moves to a real, invisible `<input>` element (`position: fixed`,
`opacity: 0`, `pointer-events: none`, 1x1px) created alongside the canvas,
instead of living on the canvas itself — the canvas keeps only the mouse
listeners; nothing about what the page looks like changes. Two details
that weren't obvious going in:

- `keydown`'s `e.preventDefault()` (present on the old canvas listener)
  had to be dropped for a plain keystroke: on a real `<input>`, preventing
  keydown's default action also suppresses the browser's own character-
  insertion step, which is the step `beforeinput` depends on — the first
  version of this fix moved focus correctly but *still* produced zero
  `text` events, for exactly this reason.
- `preventDefault()` still has to run for a **modifier-decorated**
  keystroke (Ctrl+S, Super+Z, any global keybinding's own combo): on at
  least one tested environment, a held Super (mapped from the OS's Meta)
  didn't fully suppress the browser's own text composition, leaking the
  plain letter into the buffer alongside the keybinding firing correctly.

Verified in a real Chrome tab (not just `tools/wasm-conformance.js`
against Node): Super+Z opens the editor on the browser's own
`localStorage`-backed `wm.lua`, typing inserts text, Ctrl+S saves, and the
edit applies live with the window still open — the exact `live-edit.gif`
scenario, in the browser.

## B38 — the wasm demo forced a config reload on nearly every frame, so keyboard-triggered UI never stuck

**Symptom:** found verifying the wasm demo in a real browser. Super+Space
opened the launcher for about a second, then it closed itself with no
input; Super+Q's bound `wm:close(win)` ran with no error and correctly
emptied `aster.state.windows`, yet the very next screenshot still showed
the closed window on screen; Super+1..9 workspace switching silently did
nothing. All three looked like separate bugs and were reported together.

**Cause:** `loop.lua`'s `M.tick()` re-reads `wm.lua`'s mtime every frame
(`config_mtime()`) and calls `aster.reload()` the moment it differs from
`aster.state.last_mtime` — the external-edit watch ADR-003 requires
("Reload preserves state"). `src/backends/wasm/glue.js`'s
`js_fs_list_entry` fabricated that mtime as `Math.floor(Date.now() /
1000)` on every single call instead of tracking when a path was actually
last written, so it read as "changed" essentially every tick (the WASM
backend's `requestAnimationFrame` loop calls `aster_frame()`
unconditionally, with no dirty-gating at the JS level). Every such reload
re-runs `wm.lua` and rebuilds `wm.keybindings` and `wm.launcher` from
scratch — which is why the launcher (a fresh, closed `Launcher` instance)
kept vanishing, and why Super+Q's own state change kept getting steamrolled
a frame or two later by the reload protocol's own bookkeeping. The SDL
backend never showed this: `fs_native.zig` returns the file's real mtime,
so `config_mtime()` only ever changes when `wm.lua` is actually edited.

**Fix:** `localStorageStore()` now tracks a real per-path mtime itself, in
an in-memory `Map`, advanced only by `set()`/`remove()` — a path read but
never written this session gets a stable placeholder (`0`) the first time
it's queried rather than the wall clock, since `config_mtime()`'s watch
only needs equality across ticks, not an accurate timestamp.
`js_fs_list_entry` now reads that instead of calling `Date.now()` itself.

Verified in a real Chrome tab: after the fix, Super+Space's launcher stays
open indefinitely with no input, and Super+Q closes a window and it stays
closed — confirmed via a clean `localStorage.clear()` + reload cycle, not
just observation of an already-running tab.

## B39 — `math.sin`/`cos`/`exp`/`log`/`pow` recursed forever, only in wasm

**Symptom:** opening `apps/plasma.lua` (or anything else calling
`math.sin`/`cos`/`tan`/`exp`/`log`/`log2`/`log10`, or `^` with a
non-integer exponent) froze the wasm demo's very first frame — no Lua
error, no `aster.log` line, just a JS `RangeError: Maximum call stack size
exceeded` with ~15,000 identical frames of the same wasm function. The
native SDL backend never showed it: `zig build test`, `boot-from-elsewhere`
and a 2-second dummy-driver run were all clean, because the bug is wasm-
target-only.

**Cause:** `src/backends/wasm/libc.zig` provides Lua's whole `<math.h>`
surface as `export fn`s, e.g. `export fn sin(x: f64) callconv(.c) f64 {
return @sin(x); }`. `f64` transcendentals (`sin`/`cos`/`tan`/`exp`/`log`/
`log2`/`log10`, and `pow`'s non-integer-exponent path — `std.math.pow`
takes the same route) have no native wasm instruction, so `@sin` and
friends lower to a runtime call to a libm symbol of the *exact same name*.
Zig's `compiler_rt` ships a real implementation under that name (e.g.
`compiler_rt/sin.zig` also exports `"sin"`), but this file's own `export
fn sin` already claims that symbol — so `@sin(x)` inside it calls itself,
forever. `sqrt`/`fabs`/`floor`/`ceil` never had this problem (real wasm
instructions, no runtime call at all); `asin`/`acos`/`atan`/`atan2` never
had it either, because `std.math`'s implementations of those are genuine
self-contained algorithms, not thin builtin wrappers — unlike
`std.math.tan`, which turned out to be exactly as fragile (`@tan` under
the hood) despite the more reassuring name.

**Fix:** hand-rolled range-reduced Taylor-series `sin`/`cos`/`tan`/`exp`
and an artanh-series `log`/`log2`/`log10` in `libc.zig` itself, built only
out of primitives already proven collision-free (`@floor`/`@trunc`/
`@abs`, `std.math.ldexp`/`frexp`, plain arithmetic). `pow` special-cases
an integer exponent via exact binary exponentiation (`2^40` from Lua's `^`
must come back exactly representable, or `host.wait(2^40)`'s own strict
"is this an integer" check — spec/conformance/04_events.lua — fails with
the wrong error message) and falls back to `exp(y*ln x)` only for a
non-integer exponent of a positive base. `strtod`'s decimal-exponent
scaling switched from calling this file's own `pow(10, n)` to a plain
repeated `*10`/`/10` loop — exact for the small integer exponents a
literal ever produces, and one less thing leaning on the approximate
transcendental path's precision.

Verified via `zig build test` (native — unaffected either way, but
confirms nothing regressed) and a headless Node harness that boots the
actual `aster-wasm.wasm` demo build and runs `aster_frame()` in a loop
(the wasm-conformance/wasm-tests suites don't exercise the real default
config's `plasma` window, so they never caught this) — RangeError before
the fix, dozens of clean frames after. Also confirmed live in Chrome:
`plasma`'s animated field renders correctly, proving the new `sin`/`cos`
aren't just non-recursive but numerically right.

## B40 — a `local function` declared below its first caller in the same
## file silently became a no-op, not an error

**Symptom:** `lua/aster/launcher.lua`'s new mouse support (`Launcher:click`)
did nothing at all when clicking a launcher row — no crash, no
`aster.log`, the row just never ran. The close "x" and click-away-to-close
paths (also in `input.lua`, same file) worked fine.

**Cause:** `Launcher:click` was written above the `local ROW_H`/`local
PAD`/`local MAX_VISIBLE`/`local function row_rect` block it calls, all
further down the same file. Lua locals are lexically scoped from their
declaration point onward — a reference before that point doesn't error,
it just resolves to whatever `row_rect` is in an *enclosing* scope, which
here was nothing (a global, `nil`). `Launcher:click` isn't itself wrapped
in a `pcall` anywhere on its call path from `input.lua`'s `mouse_down`, so
calling `nil(...)` should have raised — but by the time that happens the
click has already been swallowed as "handled" one level up, which is why
this read as silent rather than as a crash worth noticing.

**Fix:** moved the `ROW_H`/`PAD`/`MAX_VISIBLE`/`row_rect` block above
`Launcher:click`. Method calls (`self:popup_rect()`) don't have this
problem — those resolve through the metatable at call time, long after
the whole file has finished running top to bottom — only plain `local`
references do.

**Lesson:** a `local function` helper used by an earlier function in the
same file is a silent-`nil` trap, not a compile error, in Lua. Declare
shared locals (constants, helpers) before the first thing that uses them,
not just before their "natural" home near what they conceptually support
(`row_rect` reads as belonging next to `Launcher:render`, which is what
put it below `Launcher:click` in the first place).

## B41 — a focused window's gradient border looked fine on one side of the
## screen and nearly flat on the other

**Symptom:** two windows side by side, sharing one edge (`config/wm.lua`'s
default two-window layout, at the time, overlapped them by exactly `border`
px so the focused one's frame always wins that shared line — see B39's
commit and aster-os's own `win_render` comment this was ported from; B43
later replaced that overlap with a real gap, but this incident predates
that). Focusing the
left window showed an obvious light-to-dark sweep along its whole border.
Focusing the right one instead showed a border that looked almost one
flat dark color, particularly on the side touching its neighbor —
reported as "the frame looks consistent from one window but breaks from
the other," which sounded like a z-order/overwrite bug rather than a
rendering artifact — a first guess of "shading or gradient" got told,
correctly, that a real gradient issue should break symmetrically for
both windows, not favor one of them every time.

**Cause:** `src/render/renderer.zig`'s `gradientOutline` walked ONE
continuous `color_a -> color_b` ramp around the entire perimeter (top,
then right, then bottom, then left, `pos` incrementing the whole way) —
not four independent per-edge gradients. Which portion of that ramp any
one edge got depended on where it fell in the walk, not on that edge's
own length: the top edge (walked first) always started at pure
`color_a`; the left edge (walked last) always landed in the final sliver
approaching pure `color_b`. On the default demo's two windows — a wide
one on the left, a narrower one on the right, both the same height — the
narrower window's left/right edges are a *larger* fraction of its own
(smaller) perimeter than the wider window's are of its (larger) one, so
the narrow window's left edge occupied a `t` range compressed into
roughly 0.68-1.0 of the ramp: almost entirely `color_b`, i.e. nearly
flat. The wide window's right edge, walked second, landed around
0.23-0.5: a wide, clearly visible sweep. Both borders were genuinely
gradients the whole time — the walk-order bias just made one window's
edges much flatter than the other's, consistently, every time, which is
exactly why it looked like a directional bug rather than a rendering
artifact.

**Fix:** each of the four edges now sweeps the *entire* `color_a..color_b`
range over its own length independently, alternating sweep direction
(top: a->b, right: b->a, bottom: a->b, left: b->a) so all four corners
still land on matching colors — same visual continuity the old single
loop gave, without tying any one edge's visible range to how much of the
total perimeter it happens to be.

**Verified:** `src/render/renderer.zig`'s new test samples a 4x40 rect (the
exact "narrow and tall" shape that broke) at each end of its left and
right edges — both now span a red-to-black range over 150/255, where the
old code left the narrow rect's side edges within a few percent of each
other. Confirmed live too, via a headless Node harness (`aster_frame()`,
real `setTimeout` delays between calls rather than a tight loop) reading
`present()`'s actual pixel buffer at the shared edge for both the wasm
demo's default `hello`/`plasma` layout, both directions — reading raw
canvas pixels straight in the *browser* right after a page load looked
flat regardless of this fix, which cost real time chasing a compiler-bug
theory before the real explanation surfaced: `default_draw_frame`
animates a focus change over `FOCUS_ANIM_MS` (120ms) using a plain
lerp'd flat color, and only switches to the real `gradient_border` once
that settles (`focus_progress(win) >= 1`) — a script that clears
`localStorage` and reads pixels moments after `navigate()` is racing that
120ms window and reliably loses it, not exercising this code path at
all.

## B42 — every app's content had a 2px gap under the title bar, showing
## whatever was behind the window

**Symptom:** a thin sliver right under every window's title bar let
whatever was behind it (another window, if one happened to be there) show
through — every app, not one in particular, reported as "content isn't
stuck to the title bar's bottom edge."

**Cause:** `lua/aster/wm.lua`'s `title_bar_rect(win)` puts the title bar's
bottom edge at `win.y + self.border + theme.title_h` — 26px down, with
this repo's own `border = 2`. Every `apps/*.lua`'s own `TOP_MARGIN` (where
each app starts filling its own background — `draw(win, surface)` has no
`wm` reference, so apps can't read `self.border` and compute this exactly)
used `theme.title_h + 4` instead — 28px, picked as "probably enough
headroom" rather than derived from anything. The 2px difference
(`apps/editor.lua` used `+ 8`, a 6px gap) was never covered by either the
title bar itself (which stops at 26) or the app's own background fill
(which only starts at 28): background/whatever-was-behind-the-window
showed through that strip on every single app, all of them, all the time
— which is exactly why it looked systemic rather than an app-specific
bug.

**Fix:** `M.default_theme` (`lua/aster/wm.lua`) gained a `border = 2`
field — not read by `title_bar_rect` itself (that still uses the live
`self.border` a wm instance actually has), but a documented default for
code that has no wm reference to read the real value from. Every
`apps/*.lua`'s `TOP_MARGIN` is now `title_h + border`: exactly
`title_bar_rect`'s own bottom edge, no assumed padding on top of it. Any
per-app breathing room (space before the first line of text, etc.)
belongs in how that app positions content *within* the area TOP_MARGIN
already starts flush at, not in TOP_MARGIN itself.

## B43 — the default two-window layout had a gap at the screen edge but
## none between the windows themselves

**Symptom:** every window sits `gaps.outer` px off the screen edge — the
bar, the left/right/bottom edges, and (once double-click-to-maximize
existed) a maximized window too. But `config/wm.lua`'s two default
windows touched each other with no gap at all: reported as inconsistent
enough to be worth picking one feel and using it everywhere, not
something to leave as "well, that's just how tiling looks."

**Cause:** this repo's default layout was a direct-ish port of aster-os's
own tiling geometry, whose own comment says the quiet part out loud:
"Neighbouring rects overlap by the border width so the active window
(drawn last) shows its own 2px border at the shared edge, never a gap or
double border." That's a real design choice (one fewer visible seam to
account for), but it means `gaps.inner` (config's own name for it) was
never an actual gap — the layout math subtracted it from one window's
width and then overlapped the two rects by `border` on top of that,
which nets out to zero background pixels between them, not `gaps.inner`
of them. Screen-edge gaps and between-window gaps ended up looking like
two different design languages in the same desktop because, mechanically,
they were.

**Fix:** `config/wm.lua`'s two-window layout no longer overlaps the
windows by `border` — `gaps.inner` is now real background between them,
sized exactly like `gaps.outer` is between a window and the screen edge.
Every window edge in the default layout, touching the screen or another
window, now gets an actual gap; none of them just happen to look flush
because a border ate the space.

## B44 — double-clicking a title bar with no bar configured crashed the
## whole process

**Symptom:** `wm.bar == nil` is a supported configuration — `adopt()`
sets it explicitly, `M:render` guards it, and `input.lua`'s own drag
clamp guards it too — but double-clicking a title bar to maximize a
window with no bar configured crashed the process outright:

```
lua/aster/wm.lua:326: attempt to index a nil value (field 'bar')
stack traceback:
	lua/aster/wm.lua:326: in function 'aster.wm.toggle_maximize'
	lua/aster/input.lua:181: in function 'aster.input.dispatch'
```

`input.lua`'s dispatch calls `toggle_maximize` with no `pcall`, and
`loop.lua`'s own call into `aster.input.dispatch` has none either, so the
error propagated all the way out of `aster.frame()` and took the process
down with it — the same class of failure B7 and B8 exist to guard
against.

**Cause:** `M:toggle_maximize` (`lua/aster/wm.lua`) dereferenced
`self.bar.height` unconditionally, twenty lines away from `M:adopt`
setting `wm.bar` to `nil` when a config doesn't build one. Every other
core path that touches `wm.bar` checks it first; this one didn't.

**Fix:** `M:toggle_maximize` now reads the bar height through
`local bar_h = self.bar and self.bar.height or 0` and uses that on both
the position and size lines. With no bar, a maximized window fills the
whole screen minus `gaps.outer` — there's no bar reserving space at the
top, so there's nothing to leave room for. Lesson: `wm.bar` and
`wm.launcher` are both optional, and every new core path that reads them
needs the same guard `M:render` already carries — not just the paths
that happened to get exercised by a config with a bar.

## B45 — the launcher's "no match" row was drawn outside the popup

**Symptom:** typing a query with no matches in the launcher drew "no
match" past the bottom edge of the popup — text overflowing into whatever
window sat underneath, bottom half of the glyphs cut off by the popup's
own border. Reported after typing a query with no matches in the wasm
demo.

**Cause:** `lua/aster/launcher.lua`'s `popup_rect` sizes the popup as
`PAD * 2 + ROW_H + math.min(#items, MAX_VISIBLE) * ROW_H` — with zero
items that's `PAD * 2 + ROW_H`, one row's worth of height. But the "no
match" row itself is drawn at `row_rect(pr, 1)`, i.e. `PAD + ROW_H` down
from the top — flush against the popup's own bottom edge with no room
left for the row's own height. Popup geometry and row geometry are
computed in two different places and only line up because every non-empty
case reserves height for one row past the last item; the empty case is
the one case where that assumption breaks.

**Fix:** `popup_rect` now reserves `math.min(math.max(#items, 1),
MAX_VISIBLE)` rows instead of `math.min(#items, MAX_VISIBLE)` — at least
one row's height is always included, whether it holds a real match or
"no match".

## B46 — apps drew from the default theme, so the theme switcher only re-themed the chrome

**Symptom:** switching themes (apps/theme-switcher.lua, or the theme
config the demo ships with) re-colored the bar and the theme-switcher's
own window, but every other app's content stayed on the original colors
— measured by pixel with gruvbox active: bar and theme-switcher body both
sampled `#3C3836` (gruvbox `surface`, correct), the editor's body sampled
`#182545` (the default theme's `surface`) and hello-window's body sampled
`#1E2327`, a color in no shipped theme at all.

**Cause:** `apps/editor.lua`, `apps/calculator.lua`, `apps/snake.lua` and
`apps/hello-window.lua` all read colors from
`require("aster.wm").default_theme` — either into a module local at
`require()` time, or by name inside `draw()` but still from the same
fixed table — instead of `aster.state.wm.theme`, the table a theme switch
actually mutates. `apps/theme-switcher.lua` already had the right
pattern: `aster.state.wm and aster.state.wm.theme or
require("aster.wm").default_theme`. `apps/snake.lua` and
`apps/hello-window.lua` additionally had literal color numbers with no
theme reference at all.

**Fix:** every app above now reads `theme = aster.state.wm and
aster.state.wm.theme or default_theme` fresh inside `draw()`, and
`snake.lua`/`hello-window.lua`'s literal colors were replaced with theme
keys (`background`/`surface`/`text`/`text_dim`/`accent`/`accent_b`/`red`).
`TOP_MARGIN` in each of these files stays a module-local computed once
from `default_theme` — that's geometry (`title_h`/`border`), not a color,
and geometry doesn't change when a theme switches (see B42). Lesson: a
comment that says "no wm/theme reference, assumes the default" is only
true for geometry read once at load time; the same excuse doesn't cover
colors, which must be read live every frame.

## B47 — the editor drew straight through to whatever was behind it, and its long lines dragged the whole document sideways

**Symptom:** two separate visible bugs in `apps/editor.lua`, both reported
by using the app rather than reading the diff:

1. Whatever was behind an editor window (another window, or the previous
   frame's own leftover pixels wherever the surface wasn't otherwise
   cleared) showed straight through it — the editor never filled its own
   background before drawing text on top.
2. Scrolling a long line into view horizontally (`st.scroll_col`) dragged
   *every visible line* sideways with it, not just the one under the
   cursor — a long line elsewhere in the file would visibly shift the
   whole document, cursor line included, whenever the cursor's own line
   needed horizontal scroll.

**Cause:** (1) `M.draw` never called `r.fill_rect` for its own background
— every other app (`apps/calculator.lua`, `apps/snake.lua`) already did.
(2) the per-row render loop applied `st.scroll_col` (computed by
`scroll_into_view` from the cursor line's own content) to every line's
`line:sub(...)` unconditionally, instead of only the line the cursor is
actually on.

**Fix:** `M.draw` now fills an opaque background (`theme.surface`,
`win.x`/`win.y + TOP_MARGIN`/`win.w`/`win.h - TOP_MARGIN`) before drawing
any text. The per-row loop only applies `st.scroll_col` when `line_no ==
st.row`; every other line renders from its own column 1 and is left to
run past the window's right edge, which the window's own clip already
stops cleanly.

## B48 — the bar's centered window title collided with workspace capsules once enough workspaces existed

**Symptom:** `widgets/active-window-widget.lua` centers the focused
window's title on the whole screen width, independent of its slot in the
bar's left-to-right widget flow. aster-os never hit this (a fixed, short,
named workspace set), but aster-wm's `workspace-widget.lua` grows one
capsule per workspace with no upper bound (config/wm.lua's "+") — add
enough workspaces and the capsule row reaches all the way to screen
center, overlapping the centered title.

**Cause:** the widget always drew the title once `label ~= ""`, with no
check for whatever had already been drawn to its left by `Bar:render`'s
own running `x` cursor (launcher / clock / workspace capsules, in that
order).

**Fix:** the widget now computes the centered title's `x`, and — before
drawing — compares it (minus an 8px margin) against the `x` its own slot
was called with, i.e. how far the widgets before it have already reached.
If the centered title would start at or before that point, the widget
draws nothing and returns `0`, the same as an empty label. A title that's
about to collide disappears cleanly instead of being torn in half by the
next capsule drawn after it.

## B49 — `tools/wasm-demo.sh` broke when run from anywhere but the repo root, and `dirname "$0"` didn't fix it for a symlink

**Symptom:** `tools/wasm-demo.sh` assumed the caller's current directory
was already the repo root — every path it touched (`docs/demo/`,
`zig-out/bin/...`) was relative to whatever directory the user happened
to be in, not the script's own location, and it failed outright when run
from anywhere else.

**Cause:** the script never `cd`'d to the repo root itself, and the
first attempt at a fix (`cd "$(dirname "$0")"`) broke for the case of a
symlink pointing at the script: `dirname` on a symlink's path resolves to
the directory *the symlink lives in*, not the directory the real script
file lives in — those can differ.

**Fix:** resolve the real script path with Python first (`python3` is
already a hard dependency here, for the HTTP server this script starts) —
`os.path.realpath` follows the symlink — then take `dirname` of *that*,
and `cd` there before anything else runs. Verified against all four ways
someone might actually invoke it: absolute path, relative path from a
parent directory, a symlink to the script, and running straight from the
repo root. Lesson: `dirname "$0"` alone is never enough once a script
might be reached through a symlink — resolve the real path first.
