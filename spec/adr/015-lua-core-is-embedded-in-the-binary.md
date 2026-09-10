# ADR-015 — the Lua core is embedded in the binary, and a missing config is seeded, not left blank

**Status:** accepted (supersedes ADR-012)

## Context

ADR-012 recorded, without closing, that `aster` only runs correctly from inside a checkout of
this repo: `src/host/lua.zig`'s `package.path` resolves `lua/?.lua` etc. relative to the
process's current working directory, so a downloaded release binary run from anywhere else
fails outright:

```
$ cd /tmp/elsewhere && SDL_VIDEODRIVER=dummy aster
lua error: module 'aster' not found:
	no file 'lua/aster/init.lua'
	...
```

Shipping a release binary makes this a blocker, not a known gap. Three related findings turned
out to share one root cause and one fix:

- **A1** — the binary above.
- **A3** — even from the repo root, `~/.config/aster/wm.lua` is never written by anything: `zig
  build run`, the test suite and CI all run against the built-in fallback, so a first-time user
  sees a gray "no config" screen instead of the desktop `README.md` shows.
- **A4** — the wasm demo on GitHub Pages shows the identical fallback screen, for the identical
  reason (no `wm.lua` in the browser's `localStorage` yet), and `docs/demo/index.html` says so
  directly: "The demo has no editor app yet to write one."

`src/backends/wasm/modules.zig` already solved the wasm half of A1 (the wasm backend has no
filesystem at all, ADR-013, so it has always needed its Lua embedded) — a `package.searchers`
entry backed by `@embedFile`d strings instead of file lookup.

## Decision

**Option 1 from ADR-012: `@embedFile` the Lua core, on every backend, not just wasm.**

- `src/backends/wasm/modules.zig` moves to `src/host/modules.zig`, generalized: `register(L,
  order)` takes an `Order` (`.first` or `.last`) instead of always inserting at position 1.
- **wasm** keeps `.first` — nothing else can ever succeed there, unchanged from before this ADR.
- **every other backend** now also calls `modules.register(L, .last)`: appended after Lua's own
  preload/C-loader/Lua-file searchers, so a real file on disk always wins. A developer's
  checkout keeps editing `lua/aster/*.lua` with no rebuild (`package.path` still searches
  `lua/?.lua` first); a binary running outside any checkout — a downloaded release, or `aster`
  invoked from a different working directory — falls through to the embedded copy instead of
  failing.
- `build.zig`'s `embedded_lua` list (already shared machinery for the reason above) is embedded
  into the native `exe`/`conformance_exe`/`exe_tests` modules too (`configureCore`), not just
  `wasmModule`.
- **`config/wm.lua` is a seed, not a module.** It is embedded the same way (added to
  `embedded_lua`) but never registered as a `package.searchers` entry — `modules.zig` exposes
  its text as a plain global, `__aster_default_config`, pushed once at Lua state init. This is
  not a thirteenth `host.*` function (P2 stays twelve) — a second infrastructure global
  alongside `__native_render`, touched only by `lua/aster/loop.lua`.
- `lua/aster/loop.lua`'s `M.boot()` writes `__aster_default_config` to
  `<paths.config>/wm.lua` via `host.write` (which creates missing parent directories on its
  own) the first time `host.read` on that path returns `nil, "not_found"` — before the first
  `aster.reload()`, not inside it, so it can't interact with ADR-003's rollback protocol or run
  more than once per process. A user who later deletes the file keeps running on the last
  loaded config (already `spec/architecture.md`'s documented behavior) and is never re-seeded.

## Consequences

- A1 is closed: `aster` boots from any working directory with any (or no) `HOME`, and does so
  under `tools/boot-from-elsewhere.sh`, wired into `zig build test` (and therefore CI) as a
  regression test — runs the real `aster` binary, not `aster-conformance`, from a scratch
  directory with a scratch `$HOME`.
- A3 and A4 are closed by the same mechanism: a fresh native install and the wasm demo's first
  visit both get a real, editable `wm.lua` and boot into the actual desktop
  `apps/hello-window.lua` opens, not the fallback screen.
- `spec/adr/012-lua-core-must-not-require-the-repo-root.md`'s status is now `superseded by
  ADR-015` — the file stays; a decision is never removed, only superseded.
- The embedded copy of `lua/aster/*.lua` can drift from the checkout's copy of the same files
  only in the sense that any build artifact can be stale relative to uncommitted edits — the
  embedded copy always matches whatever was on disk when the binary was built, same as before
  for wasm.
- Not a change to `spec/host-contract.md` — no host.* function is added, removed or changed.
