# Third-party notices

aster is MIT-licensed (see [`LICENSE`](LICENSE)). It vendors the following third-party
material, unmodified except where noted.

## Lua 5.4

Path: `libs/lua-5.4/`
Version: 5.4.8
License: MIT

```
Copyright (C) 1994-2025 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## VGA 8x16 console font

Path: `src/render/font_data.zig`
Source: `/usr/share/kbd/consolefonts/default8x16.psfu.gz` (Linux console fonts, `kbd`
package)
License: Public domain

`font_data.zig` is generated data — a bitmap glyph table extracted from the console font
above, not a copy of any part of the `kbd` package's own (GPL-licensed) source code. Console
bitmap fonts of this shape descend from the original IBM VGA ROM font and are treated as
public domain by every Linux distribution that ships them.
