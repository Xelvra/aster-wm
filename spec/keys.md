# Key names

Normative, exactly as much as [`spec/host-contract.md`](host-contract.md) is. This is the
complete set of strings a backend may put in the `key` field of a `key_down` or `key_up`
event. Changing this list changes the host contract and therefore requires an ADR.

## The complete set

Letters and digits, always lowercase:

```
a b c d e f g h i j k l m n o p q r s t u v w x y z
0 1 2 3 4 5 6 7 8 9
```

Whitespace and editing:

```
space  enter  escape  tab  backspace  delete  insert
```

Navigation:

```
up  down  left  right  home  end  pageup  pagedown
```

Function keys:

```
f1  f2  f3  f4  f5  f6  f7  f8  f9  f10  f11  f12
```

Punctuation:

```
minus  equals  bracketleft  bracketright  semicolon  apostrophe  grave  backslash
comma  period  slash
```

## Keys are not text

`key_down` carries the physical key, for shortcuts. `text` carries the resulting text, for
typing, as UTF-8 after the layout and IME have run. They are two separate events and a
backend must deliver both — never one derived from the other.

This is why the names above are lowercase and stay lowercase: Shift is reported in `mods`,
not by changing which key name is sent. A character that Shift produces arrives as a `text`
event.

## Layout is the host's business

Keyboard layout, including switching between layouts, is handled entirely by the host — SDL
and evdev do it themselves, WebAssembly gets it from the browser, and the bare-metal backend
carries its own table. The contract has no call for it, and Lua never sees a layout.

## Default keybindings

Not normative — an ordinary `wm:bind()` call in `config/wm.lua`, changeable like anything
else there. Listed here because it's the one place to look instead of reading the whole
file.

```
Super+Space        toggle the launcher
Super+Z            open the editor on config/wm.lua itself
Super+N            open a new hello-window
Super+Q            close the focused window
Super+1..9         switch to workspace 1..9
Super+Shift+1..9   move the focused window to workspace 1..9 and follow it
Super+Shift+R      reload wm.lua (core-level — lua/aster/input.lua, works even if
                    config/wm.lua is broken or doesn't bind it)
Escape             dismiss the reload error bubble (core-level, same reason)
```

## Mouse

Not normative either, and — unlike the keybindings above — not something `config/wm.lua`
can override: these gestures live in `lua/aster/input.lua` itself, not in a `wm:bind()` call,
so reading the config is not a substitute for reading this list. Listed here for the same
reason as the keybindings: one place to look instead of the whole file.

```
click on a bar widget         runs that widget's own click handler (core-level, bar.lua)
click on a window              focuses and raises it (core-level)
click on a window's title bar  starts a drag (core-level)
double-click a title bar       toggles maximize/restore (core-level)
click a window's close button  closes it (core-level)
click inside a window's body   forwards to win.app.click, if the app has one (core-level
                                 routing; app.click itself is whatever config/wm.lua wired up)
click outside the launcher     closes it, while it's open (core-level)
click a launcher row           runs that entry and closes the launcher (core-level)
click the launcher's "x"       closes it (core-level)
```

`key_up` and `scroll` events are received by `input.lua` but not routed anywhere yet — no
app or core path ever sees them.
