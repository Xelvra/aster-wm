/* Wasm-target setjmp/longjmp declarations for the wasm backend's build of
 * Lua (ADR-013). Not from wasi-libc — Lua only needs jmp_buf plus the two
 * function prototypes; LLVM's WebAssemblyLowerEmscriptenEHSjLj pass matches
 * calls to functions literally named setjmp/longjmp and rewrites them to
 * call __wasm_setjmp/__wasm_setjmp_test/__wasm_longjmp (implemented in
 * rt.c), so neither function needs (or gets) a body here.
 *
 * jmp_buf's layout must be large enough for rt.c's struct jmp_buf_impl:
 * one pointer (func_invocation_id), one uint32_t (label), then a two-word
 * arg struct (env pointer, int val) — 16 bytes on wasm32. Rounded up to
 * four pointer-sized words for headroom and alignment.
 */
#ifndef ASTER_WASM_SETJMP_H
#define ASTER_WASM_SETJMP_H

typedef struct { void *__opaque[4]; } jmp_buf[1];

int setjmp(jmp_buf env);
_Noreturn void longjmp(jmp_buf env, int val);

#endif
