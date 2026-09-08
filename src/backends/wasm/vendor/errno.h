/* Minimal errno.h for the wasm backend's freestanding Lua build
 * (ADR-013). Only referenced inside lauxlib.c's luaL_fileresult/
 * luaL_execresult — POSIX file/process error reporting the wasm backend
 * never calls (no real files, no processes); linked but dead. */
#ifndef ASTER_WASM_ERRNO_H
#define ASTER_WASM_ERRNO_H

extern int errno;

#endif
