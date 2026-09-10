# ADR-016 — Every window floats; real tiling is deferred, not rejected

**Status:** accepted

## Context

`aster-os`, the project this one grew out of (ADR-001), had a `layout_pass` that tiled
windows: a fresh two-window desktop came up as a 60/40 split, and neighbouring rects
overlapped by the border width so a shared edge showed exactly one border and never a gap.
This repo ported that desktop's *look* (theme, frame, bar, launcher) but not that engine.

That leaves a question the code cannot answer on its own, and which the README's own pitch
makes load-bearing: is tiling **gone** — a non-goal like the compositor, the Wayland client
support and the GPU path in `architecture.md`'s "What is deliberately absent" — or is it
**not written yet**? The two answers imply opposite things for anyone reading `wm:open`,
`win.floating` and the unused `wm.layout` field and deciding whether to send a patch.

`config/wm.lua` also seeds two windows in that same 60/40 split at first boot. Read without
this decision recorded, that geometry looks like the beginning of a tiler that someone
abandoned half-finished, rather than what it is.

## Decision

- **Every window is floating.** `wm:open` positions by plain `x/y/w/h`; `win.floating` is
  always true and `wm.layout` is stored but read by nothing. There is no layout pass, no
  BSP tree, no master-stack, and no automatic re-layout on open, close, or resize.
- **Tiling is deferred to phase B, not rejected.** It is not a non-goal and does not belong
  in `architecture.md`'s "What is deliberately absent" list, which is reserved for things
  this project will never do. When it lands it is BSP *and* master-stack, switchable at
  runtime, plus drag-resize and multi-monitor — and `host.info().outputs` is already an
  array precisely so multi-monitor is not a breaking contract change (ADR-004's era
  decision, still standing).
- **The default two-window layout is a seed, not a tiler.** `config/wm.lua` writes the
  static geometry a live tiler would have produced for two windows, so a fresh desktop has
  something to drag between and switch focus in. Nothing keeps it there: move or close a
  window and it stays moved.
- **That seed uses real gaps, unlike the layout it was ported from.** `gaps.inner` is
  actual background between the two windows, the same way `gaps.outer` is background
  between a window and the screen edge — not `aster-os`'s border-overlap trick. See B43 in
  `troubleshooting.md`: the overlap saved a few pixels and bought two different design
  languages in one desktop.
- **When tiling is written, it is written in Lua**, in `lua/aster/` or above it, under the
  same line budget as everything else. Nothing about it reaches the renderer: rule 3 does
  not bend for a layout engine, and `spec/host-contract.md` gains nothing — a tiler needs
  `host.info().outputs` and arithmetic, both of which exist.

## Consequences

- `architecture.md`'s "Windows and apps" can keep saying "every window is floating (no
  tiling layout exists)" as a plain statement of today, with this file as the reason it is
  a stage rather than a verdict.
- A contributor who wants tiling now knows it is welcome work and knows its shape, without
  the core having to carry a half-built layout pass in the meantime to signal that.
- The README does not claim a tiling WM. It claims "a bar, a launcher, a live editor,
  workspaces, themes", which is what exists — the earlier wording that did claim tiling was
  corrected in M6's documentation pass, and this decision is why it stays corrected until
  the engine is real.
- Deferring costs nothing structurally: because layout is policy and policy lives in Lua
  (rule 3), adding a tiler later touches no Zig, no backend and no conformance script. It
  is the cheapest possible thing to postpone, which is the whole argument for postponing it.
- `wm.layout` stays in `adopt`'s reset list even though nothing reads it. It is the field a
  tiler will switch on, and resetting it on reload is already correct behaviour under
  ADR-003; removing it and adding it back would be churn.
