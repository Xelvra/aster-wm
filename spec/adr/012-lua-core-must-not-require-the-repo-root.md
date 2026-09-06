# ADR-012 — the Lua core must not require running from the repo root

**Status:** accepted (records a known gap; does not close it)

## Context

`src/host/lua.zig`'s `package.path` is set to
`lua/?.lua;lua/?/init.lua;./?.lua;./?/init.lua`, resolved relative to the process's current
working directory. `require("aster")`, `apps/*.lua`, and `config/wm.lua` (when it does
`require("aster.wm")` and similar) all depend on this. Running the binary from anywhere other
than the repository root fails outright:

```
$ cd /tmp/elsewhere && aster
lua error: module 'aster' not found:
    no file 'lua/aster/init.lua'
    no file './aster.lua'
```

This is not a problem M4 introduced and not a problem M4 needs to solve, but it is a real
blocker for the project's own stated goal of shipping a downloadable release binary: README
already promises "Grab a binary from Releases", and the desktop-notes project vision names a
downloaded, double-clicked binary as the definition of done for that phase. A binary that
only runs from inside a git checkout of its own source does not meet that bar. `assets/font.ttf`
already solved the equivalent problem for the font (`@embedFile`, ADR-006); `lua/aster/` and
`apps/` are more important than the font and have no equivalent solution yet.

## Decision

Not made yet. Two real options, recorded so the eventual choice is deliberate:

1. **`@embedFile` the Lua core**, the same mechanism ADR-006 uses for the font: embed
   `lua/aster/*.lua` (and, more speculatively, `apps/`) into the binary at build time,
   loading modules from an in-memory table instead of `package.path`'s file-search
   mechanism. Consistent with "one file on disk" as the whole point of the project, and
   removes the runtime dependency on `lua/` existing anywhere. Requires either a build-time
   step that concatenates/registers every `.lua` file under `lua/aster/`, or a custom
   `package.searchers` entry backed by embedded strings instead of the filesystem.
2. **Resolve an install path from `host.info().paths`**, falling back to the current
   CWD-relative search for development (`zig build run`). Closer to how most software finds
   its own data files, and keeps `lua/aster/*.lua` as plain files editable without a rebuild
   even in an installed copy (arguably a feature, not just a workaround, given the whole
   premise is that `wm.lua` is user-editable) — but a "which paths, in what order" scheme
   needs a real design, and differs by platform.

`apps/` is deliberately not resolved by this decision either way yet: whether shipped apps
travel with the core (embedded, like option 1) or stay separate files a user could override
(like option 2) changes what "install a themed variant of hello-window" even means, and that
is its own conversation.

## Consequences

- Until this is resolved, `aster` (and any binary built from this repo) only runs correctly
  when the current working directory is the repository root. This is a real blocker for
  producing a release binary, not a cosmetic one.
- Whichever option is chosen is a real implementation project on its own — this ADR records
  the fork, not the fix.
