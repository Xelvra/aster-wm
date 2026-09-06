# ADR-007 — Windows have ids; apps are registered, not dispatched

**Status:** accepted

## Context

In the code inherited from `aster-os`, a window is identified by its title string, and the
contents of a window are drawn by a hardcoded chain in the composition root:

```lua
if title == "repl" then repl_render()
elseif title == "editor" then editor_render()
...
```

Two consequences, both fatal to the project's goals. Nobody outside the repo can add an app
without patching the core, so `apps/` and "send us a PR" are fiction. And two windows can
never share a title, so phase B cannot have two terminals.

## Decision

- A window has an integer `id`, allocated from `aster.state.next_id` and never reused.
  `title` is an ordinary attribute: mutable, non-unique.
- An app is a table: `draw` (required), `key`, `text`, `tick` (optional). A window holds a
  reference to its app and to a private `state` table the core never touches.
- The core contains no list of apps and no reference to any app by name, including the ones
  shipped in this repo. `config/wm.lua` requires them like any third-party app would.
- `app.draw` is called inside a clip rectangle, wrapped in `pcall`. An app that crashes
  closes its own window and logs; it does not take the desktop with it.

## Consequences

- `apps/hello-window.lua` becomes writable, and with it the whole contributor story.
- Phase B can open as many terminals as it likes.
- The editor, file browser and REPL live in `apps/`, which is what keeps the core inside its
  line budget — and is the proof that the core really contains nothing extra.
