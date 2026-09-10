# Code style

Short, because the rule that matters most is: match what's already in the file you're
editing. This page only writes down the parts that aren't obvious from reading the code.

## Comments are facts, not narration

A comment says *what* isn't obvious or *why* it's written this way — never *what happened*
while someone was debugging it. An incident belongs in
[`spec/troubleshooting.md`](troubleshooting.md); a comment may point at it by id
(`// see B3`) and nothing more. Don't restate in prose what a well-named function already
says.

## Zig

- One backend, one file under `src/backends/<name>/`. It implements the
  `info`/`surface`/`present`/`wait`/`clock` quintet from [`host-contract.md`](host-contract.md)
  (ADR-010: a backend's notion of wall-clock time, if any, is its own decision); filesystem
  and log are shared (`src/host/fs.zig`) and every backend gets them for free.
- `bindings.zig` naming: `l`-prefixed functions (`lWait`, `lInfo`, …) are the twelve
  `host.*` contract functions; `n`-prefixed functions (`nFillRect`, `nBlit`, …) are
  `__native_render`, the renderer library, which is not part of the contract.
- Register Lua C functions with `lua_createtable` + `luaL_setfuncs` by hand, never
  `luaL_newlib`/`luaL_newlibtable` — see B2 in `troubleshooting.md` for why the macro
  doesn't survive `@cImport`.
- Push Lua strings with `lua_pushlstring(L, ptr, len)`, not `lua_pushstring`, unless the
  pointer is a string literal or otherwise guaranteed null-terminated. See B4 in
  `troubleshooting.md`.
- This Zig's stdlib carries the `std.Io` redesign (no bare `std.fs`/`std.time`). Grep
  `/usr/lib/zig/std/` before trusting a remembered signature; see B1 in
  `troubleshooting.md`.
- The renderer (`src/render/`) draws rectangles and glyphs onto a `Surface`. It never
  learns what a window, a title bar, or a workspace is — that knowledge stays in Lua
  (`spec/architecture.md`, rule 3).

## Lua

- Every module in `lua/aster/` returns a plain table `M` and does its `require`s at the
  top of the file. `setmetatable(t, { __index = SomeTable })` for one level of method
  dispatch is fine and used (`wm`, `lua/aster/bar.lua`'s `Bar`, `lua/aster/launcher.lua`'s
  `Launcher`) — what's off the table is a multi-level inheritance chain, which nothing here
  needs. `wm`'s own metatable additionally has a `__newindex` for `theme` specifically (see
  B35 in `troubleshooting.md` for why a plain field wasn't enough) — that's the one place a
  metatable does more than method dispatch, and it stays scoped to that one field.
- Text width is always `r.text_width(str)` (or `r.line_height()`), never a hardcoded
  per-character pixel constant. The bitmap fallback font and the TTF font don't advance by
  the same number of pixels per glyph, so a fixed-width assumption is correct under at most
  one of the two — see `apps/editor.lua`'s cursor/scroll math for what actually measuring
  it looks like.
- `lua/aster/` has a 1,600-line budget across the whole directory, checked by
  `tools/budget.sh` in `zig build test`. If a change pushes it over, that's a sign the code
  belongs in `apps/`, not that the budget is wrong.
- An app is a table with `draw` and optional `key`/`text`/`tick`. Nothing in `lua/aster/`
  is allowed to know the name of any specific app, including the ones shipped in this repo.
- Errors from an app's callback are caught at the call site and close only that app's
  window — never let one app's bug reach `wm.lua`'s own state.

## Both

- English only: code, comments, identifiers, commit messages. No exceptions.
- No defensive code against inputs that can't occur — `aster.*` (`aster.boot`/`frame`/
  `shutdown`) is Zig calling Zig, a closed contract only the host driver calls; trust the
  shapes it defines. This does **not** extend to `host.*` or `__native_render`: both are
  global tables reachable directly from arbitrary app Lua exactly the same way, so "an input
  that can't occur" doesn't exist for either. Every argument either one takes must be
  validated and turned into a real Lua error (`luaL_argerror`) on failure, never a Zig panic
  — see B17 and B31 in `troubleshooting.md`.
