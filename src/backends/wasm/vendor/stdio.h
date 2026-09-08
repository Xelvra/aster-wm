/* Minimal stdio.h for the wasm backend's freestanding Lua build (ADR-013).
 *
 * Two unrelated reasons this exists: lauxlib.c's luaL_loadfilex needs
 * FILE/fopen/getc/etc. to compile even though the wasm backend never
 * calls it (loads Lua modules from an embedded package searcher instead
 * of real files — see libc.zig's header comment), and lbaselib.c's
 * `print` genuinely does write through `fwrite(..., stdout)` on every
 * backend today (lua_writestring/lua_writeline in lauxlib.h) — nothing
 * routes it through host.log yet, on this backend or any other, so
 * fwrite/fflush are no-ops here rather than a partial special case. */
#ifndef ASTER_WASM_STDIO_H
#define ASTER_WASM_STDIO_H
#include <stddef.h>

typedef struct FILE FILE;

#define EOF (-1)
#define BUFSIZ 512

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

FILE *fopen(const char *path, const char *mode);
FILE *freopen(const char *path, const char *mode, FILE *f);
int fclose(FILE *f);
size_t fread(void *ptr, size_t size, size_t n, FILE *f);
size_t fwrite(const void *ptr, size_t size, size_t n, FILE *f);
int fflush(FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
int getc(FILE *f);
int snprintf(char *buf, size_t size, const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);

#endif
