/* Minimal stdlib.h for the wasm backend's freestanding Lua build
 * (ADR-013). Backed by src/backends/wasm/libc.zig. */
#ifndef ASTER_WASM_STDLIB_H
#define ASTER_WASM_STDLIB_H
#include <stddef.h>

void *malloc(size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
_Noreturn void abort(void);
char *getenv(const char *name);
double strtod(const char *s, char **endptr);
int abs(int x);

#endif
