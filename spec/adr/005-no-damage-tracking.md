# ADR-005 — No damage tracking in v1

**Status:** accepted

## Context

Damage tracking (presenting only the rectangles that changed, instead of the whole surface)
is a standard compositor optimization, and it's tempting to build it in from the start. But
a full-frame present at 1080p is roughly an 8 MB memcpy — cheap on every backend this
project targets — and damage tracking is real complexity: every drawing call has to merge
into a damage region, and every backend has to honor partial presents correctly.

Building it before it's known to be a problem is exactly the kind of unbounded platform work
this project exists to avoid.

## Decision

v1 has no damage tracking. `host.present()` always sends the whole surface.

The Lua side is already prepared for the cheapest possible optimization instead: `dirty` is a
plain boolean, and `aster.frame()` only calls `render` + `present` when something actually
changed. An idle desktop draws nothing at all, which is a bigger win than partial presents
would be.

If full-frame presents genuinely become a measured problem, `host.present(x, y, w, h)` will
be added as an **optional** extension, announced through `host.info().caps.damage`, so
backends that don't need it aren't forced to implement it.

## Consequences

- Every drawing function in the renderer stays free of damage-region bookkeeping.
- The only optimization that exists today is "don't draw when nothing changed", which is
  also the cheapest one and needs no host contract support at all.
- Adding `caps.damage` later is additive, not a breaking change to `host.present()`'s
  no-argument form.
