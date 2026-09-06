# ADR-006 — TTF rasterizer with a bitmap fallback

**Status:** accepted

## Context

The bitmap font inherited from `aster-os` (`font_data.zig`, 112 lines) covers ASCII only, but
the host contract's `text` event delivers UTF-8 (`{type="text", text="á"}`). An editor that
can't render diacritics is broken for most of the world outside English, and the editor is
the app that appears in the project's own headline GIF.

Adding a TTF rasterizer is real, backend-independent Zig work with no shortcut in the
inherited code — everything else in the renderer had something to port from; this doesn't.

## Decision

Ship a small TTF rasterizer (`src/render/ttf.zig`, a port of the public-domain
`stb_truetype`, rasterization only) plus a glyph cache (`src/render/font.zig`: codepoint →
bitmap at the single fixed UI pixel size, LRU). The font itself is `@embedFile`-d into the
binary from `assets/font.ttf` under an SIL OFL or public-domain license, recorded in
`THIRD-PARTY-NOTICES.md`.

The inherited bitmap font (`font_data.zig`) stays as a **built-in fallback**: if the bundled
`assets/font.ttf` fails to parse, the desktop boots in bitmap mode and logs why through
`host.log`. A desktop that fails to boot over a font problem is worse than one with an ugly
font.

This lands before the "beauty" milestone (M6), not after — everything drawn on screen goes
through text rendering, and changing typography after the demo GIFs are recorded would mean
recording them twice.

## Consequences

- `assets/font.ttf` ships in the binary, not read through `host.read` — so a bare-metal
  backend never needs a font file on a filesystem it may not have. This also means a
  *missing* font is a `zig build` error, not a runtime state: `@embedFile` requires the file
  to exist at compile time. The bitmap fallback therefore only ever covers the bundled font
  failing to **parse**, never the font being absent — "ships without a font" is not a state
  this binary can be in.
- Rasterizing a glyph on every frame is the one place performance could realistically break;
  the glyph cache is mandatory, not an optimization to add later. The cache key is the
  codepoint alone, because the UI renders at one fixed pixel size (`font.zig`'s
  `pixel_height`); a second on-screen size would need the key to become codepoint+size, which
  is a real change to make then, not something already built in.
- The bitmap fallback means a bundled font that fails to parse is a degraded desktop, never a
  broken one.
