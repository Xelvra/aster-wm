/* Minimal signal.h for the wasm backend's freestanding Lua build
 * (ADR-013). lstate.h only needs sig_atomic_t for its `trap`/`hookmask`
 * fields — the real signal handling (SIGINT, setsignal) lives in lua.c,
 * which isn't compiled into aster at all (see build.zig's lua_sources),
 * on any backend. */
#ifndef ASTER_WASM_SIGNAL_H
#define ASTER_WASM_SIGNAL_H
typedef int sig_atomic_t;
#endif
