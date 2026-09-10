-- themes/default.lua — the colors aster.wm.default_theme already ships
-- (a direct port of aster-os's own theme.lua), spelled out explicitly so
-- "default" is a theme like any other (pick it from a launcher/switcher
-- later, diff it against the others here). A partial table would work too
-- — wm.theme falls back to aster.wm.default_theme for any key it doesn't
-- set (see D4/B35 in spec/troubleshooting.md) — this one just happens to
-- repeat every key.
return {
  background = 0x111826,
  surface = 0x182545,
  surface_alt = 0x223454,
  text = 0xdddddd,
  text_dim = 0x798bb2,
  accent = 0x82dccc,
  accent_b = 0x00aa84,
  accent_dark = 0x007d6f,
  inactive = 0x798bb2,
  red = 0xff6b6b,
}
