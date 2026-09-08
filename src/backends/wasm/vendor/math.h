/* Minimal math.h for the wasm backend's freestanding Lua build (ADR-013).
 * Backed by src/backends/wasm/libc.zig. HUGE_VAL uses Clang's builtin
 * directly since there's no libm to define the macro for us. */
#ifndef ASTER_WASM_MATH_H
#define ASTER_WASM_MATH_H

#define HUGE_VAL (__builtin_huge_val())

double sqrt(double x);
double fabs(double x);
double floor(double x);
double ceil(double x);
double fmod(double x, double y);
double pow(double x, double y);
double exp(double x);
double log(double x);
double log2(double x);
double log10(double x);
double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);
double ldexp(double x, int exp);
double frexp(double x, int *exp);
double modf(double x, double *iptr);

#endif
