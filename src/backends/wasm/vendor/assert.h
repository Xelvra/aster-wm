/* Minimal assert.h for the wasm backend's freestanding Lua build
 * (ADR-013). Included by several Lua sources but never actually called
 * (audited — Lua's own lua_assert, not this, is what those files use). */
#ifndef ASTER_WASM_ASSERT_H
#define ASTER_WASM_ASSERT_H
#define assert(x) ((void)0)
#endif
