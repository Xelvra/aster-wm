/* Minimal locale.h for the wasm backend's freestanding Lua build
 * (ADR-013). Included by llex.c/lobject.c/lstrlib.c but never actually
 * used (no setlocale/localeconv call in the compiled source set) — Lua's
 * only real touchpoint, lua_getlocaledecpoint(), is redefined at compile
 * time (build.zig's wasm step passes -Dlua_getlocaledecpoint()=...) to
 * a plain '.' instead of routing through localeconv(), so this header
 * only needs to exist, not declare anything. */
#ifndef ASTER_WASM_LOCALE_H
#define ASTER_WASM_LOCALE_H
#endif
