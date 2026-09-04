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
