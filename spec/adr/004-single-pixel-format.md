# ADR-004 — Single pixel format: xrgb8888

**Status:** accepted

## Context

`Surface` is the one piece of shared state that crosses the host contract boundary, and the
renderer has to agree with every backend on what its bytes mean. Supporting several pixel
formats from day one — to save some backend a conversion — means every drawing function in
the renderer grows a format branch before a second backend even exists to justify it.

## Decision

v1 of the host contract supports exactly one pixel format: `xrgb8888`, little-endian, 32 bpp.
A backend whose native format differs (a framebuffer in `rgb565`, for instance) converts it
itself, on its own side of the contract.

`host.info().format` reports the value for documentation and for conformance to check; in
v1 it is always `"xrgb8888"`.

## Consequences

- The renderer (`src/render/`) has one code path per drawing primitive, not one per format.
- A future second format is a new host contract function or field, decided when a real
  backend actually needs it — not spent in advance on a hypothetical one.
- Backends pay the conversion cost, if any, once per present, in the layer that already
  knows their native hardware format.
