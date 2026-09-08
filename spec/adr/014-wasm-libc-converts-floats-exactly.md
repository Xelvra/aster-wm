# ADR-014 — the wasm libc converts floats exactly, instead of leaning on `std.fmt`

**Status:** accepted

## Context

ADR-013 left the wasm backend owning a small libc surface, including the number formatting
`lstrlib.c` calls through `l_sprintf` — every `string.format("%.2f", …)`, every
`tostring(number)`, every `%q`. `src/backends/wasm/libc.zig` implemented the float
conversions by delegating to `std.fmt.float.render`, on the assumption that a standard
library's float formatter is a formatter for C's `%f`/`%e`/`%g`.

It isn't the same operation. `std.fmt.float.render` rounds the *shortest decimal that
round-trips back to the same double*; C converts the double's *exact* value and rounds that
to the requested precision. Those differ whenever the shortest form sits on the other side of
a rounding boundary from the real value: `%.2f` of 1.005 is `1.01` under `render` and `1.00`
in C, because the double spelled 1.005 is really 1.00499999999999989342.

Measured against glibc over 399 conversions, 21 disagreed after two unrelated bugs were
fixed, and every one of the 21 was this. The effect is a **cross-backend difference**:
`string.format("%.2f", x)` returns one string under SDL, where the real libc does the
conversion, and another under wasm. `spec/architecture.md`'s promise is that the same
`wm.lua` behaves the same on every backend, and this quietly wasn't true for a bar clock or
any percentage a theme prints. See B27 in `spec/troubleshooting.md` for how it surfaced.

## Options considered

1. **Leave it, document it as a known limitation.**
   - Pro: no code. The divergence only shows in the last printed digit, and `tostring()`
     (`"%.14g"`) is unaffected — 14 significant digits is inside the shortest round-trip form
     for every double.
   - Con: it is a behavioural difference between backends that no test can be written
     against, in the one direction the project promises there isn't one. "The desktop adapts
     where a backend genuinely can't do something" is about capabilities, not about arithmetic
     silently giving different answers.
2. **Vendor a C `printf` implementation (musl's `vfprintf`) the way ADR-013 vendors `rt.c`.**
   - Pro: known-correct, no new algorithm to own.
   - Con: musl's float path pulls in its own multi-precision machinery and `long double`
     handling; it is far more code than the whole rest of this libc, for the one conversion
     Lua needs. ADR-013 vendored 83 lines because they were the only way to make `pcall`
     work; this would be several hundred to replace something we already have a shape for.
3. **Convert exactly, in the digit array we already produce.**
   - Pro: no dependency on how `std.fmt` chooses to round, and the algorithm is small
     because binary-to-decimal needs no division. Every finite double is `m × 2^e` with
     `m < 2^53`; for `e >= 0` the value is the integer `m << e`, and for `e < 0` it is
     `m / 2^k = m × 5^k / 10^k` — so the exact digits are those of `m × 5^k` with the point
     `k` places from the right. Both reduce to multiplying a decimal digit array by 2 or by 5.
   - Con: the project owns a rounding implementation, and its cost is set by the exponent
     rather than by the requested precision — a denormal is ~1074 passes over ~770 digits.

## Decision

Convert exactly (option 3). `libc.zig` builds the full decimal expansion of the double and
rounds it to the requested precision, to nearest with exact ties to even, which is what C's
default rounding mode does. `std.fmt.float.render` is no longer used for `%f`, `%e` or `%g`.

The buffer is sized for the worst case the format can ask for (`2^53 × 5^1074` is 767
digits) rather than for the worst case anyone expects to hit.

## Consequences

- `string.format` returns the same bytes on wasm as on SDL. Verified differentially against
  glibc: 12,029 doubles — random bit patterns across the whole exponent range plus the
  usual tie and boundary cases — times ten format specifiers, with one exception below.
- The exception is glibc's, not ours: `%#g` of 999999.5 prints `1.e+06` there and
  `1.00000e+06` here. glibc contradicts itself on it — `%#g` of 1000000.0, the same value
  after rounding, prints `1.00000e+06`, and `%#.3g` of 9999.0 prints `1.00e+04` — and `#`
  is defined to keep trailing zeros. Python's own dtoa agrees with this file. Do not "fix"
  this by matching glibc.
- Cost is bounded by the exponent, not the precision. Ordinary values (3.14, a percentage,
  a clock) take about fifty passes over seventeen digits; only denormals approach the worst
  case, and nothing on a frame path formats one.
- This is a decision about what a backend is built from, the same category as ADR-013, and
  it does not touch `spec/host-contract.md`'s twelve functions.
- A future Zig with an exact fixed-precision mode in `std.fmt` would make this deletable,
  but nothing about that is required: the code has no dependency left to track.
