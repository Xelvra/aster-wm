/* Minimal ctype.h for the wasm backend's freestanding Lua build (ADR-013).
 * ASCII-only, backed by src/backends/wasm/libc.zig — Lua never sets a
 * locale, so "the C locale" is the only behavior these need. */
#ifndef ASTER_WASM_CTYPE_H
#define ASTER_WASM_CTYPE_H

int isalpha(int c);
int isdigit(int c);
int isalnum(int c);
int isspace(int c);
int iscntrl(int c);
int ispunct(int c);
int isupper(int c);
int islower(int c);
int isxdigit(int c);
int isgraph(int c);
int toupper(int c);
int tolower(int c);

#endif
