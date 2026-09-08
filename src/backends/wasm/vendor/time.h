/* Minimal time.h for the wasm backend's freestanding Lua build (ADR-013).
 * Both `clock()` and `time()` only ever feed ltablib.c's table.sort pivot
 * randomization and lstate.c's hash seed — not a security boundary
 * (spec/architecture.md's security model) — so libc.zig's monotonic
 * counter is a deliberately weak but sufficient source of "different
 * every call", not a real wall clock. */
#ifndef ASTER_WASM_TIME_H
#define ASTER_WASM_TIME_H

/* Both types are 8 bytes to exactly match libc.zig's i64 return value —
 * the C declaration here must agree with the actual ABI width of the
 * compiled Zig function, not just with a "plausible" libc typedef. */
typedef long long clock_t;
typedef long long time_t;

clock_t clock(void);
time_t time(time_t *out);

#endif
