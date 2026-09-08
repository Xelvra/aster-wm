//! The libc surface Lua 5.4's core and stdlib (lapi/lauxlib/lbaselib/lcode/
//! lcorolib/lctype/ldebug/ldo/ldump/lfunc/lgc/llex/loadlib/lmathlib/lmem/
//! lobject/lopcodes/lparser/lstate/lstring/lstrlib/ltable/ltablib/ltm/
//! lundump/lutf8lib/lvm/lzio — build.zig's `lua_sources`) actually call,
//! for wasm32-freestanding (ADR-013: no wasi-libc on this backend, so
//! nothing here comes for free). Bounded by an audit of those files, not
//! a general-purpose libc — grep for a symbol here before assuming it's
//! missing by accident.
//!
//! Not covered here because the compiled Lua sources never reach them at
//! runtime on this backend (verified: only reachable via `os`/`io`, which
//! aren't compiled in, or via `LUA_USE_DLOPEN`, which isn't defined):
//! system, getenv, dlopen/dlsym/dlclose. `fopen`/`fclose`/`fread`/`feof`/
//! `ferror` are compiled into lauxlib.c's `luaL_loadfilex` but that path is
//! only used by the SDL backend's conformance-script runner
//! (src/host/lua.zig's `runScript`) and `require`'s file searcher — the
//! wasm backend replaces both with an embedded-module package searcher
//! (src/backends/wasm/modules.zig), so these are stubs that always fail,
//! never load-bearing.

const std = @import("std");
const allocator = std.heap.wasm_allocator;

// ---- allocator: malloc/realloc/free ----------------------------------
//
// C's free/realloc don't carry a size, so each allocation gets an
// `alloc_align`-byte header in front of it storing the total (header +
// payload) size `alloc` actually requested.

const alloc_align: usize = 16; // covers every alignment Lua's structs need

fn headerOf(ptr: [*]u8) *usize {
    return @ptrCast(@alignCast(ptr - alloc_align));
}

export fn malloc(size: usize) callconv(.c) ?[*]u8 {
    if (size == 0) return null;
    const total = size + alloc_align;
    const mem = allocator.alignedAlloc(u8, .fromByteUnits(alloc_align), total) catch return null;
    headerOf(mem.ptr + alloc_align).* = total;
    return mem.ptr + alloc_align;
}

export fn free(ptr: ?[*]u8) callconv(.c) void {
    const p = ptr orelse return;
    const total = headerOf(p).*;
    const base: [*]align(alloc_align) u8 = @alignCast(p - alloc_align);
    allocator.free(base[0..total]);
}

export fn realloc(ptr: ?[*]u8, size: usize) callconv(.c) ?[*]u8 {
    const p = ptr orelse return malloc(size);
    if (size == 0) {
        free(p);
        return null;
    }
    const old_total = headerOf(p).*;
    const base: [*]align(alloc_align) u8 = @alignCast(p - alloc_align);
    const new_total = size + alloc_align;
    const new_mem = allocator.realloc(base[0..old_total], new_total) catch return null;
    headerOf(new_mem.ptr + alloc_align).* = new_total;
    return new_mem.ptr + alloc_align;
}

// ---- string.h ----------------------------------------------------------

export fn memcpy(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    @memcpy(dst[0..n], src[0..n]);
    return dst;
}

export fn memmove(dst: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    if (@intFromPtr(dst) < @intFromPtr(src)) {
        var i: usize = 0;
        while (i < n) : (i += 1) dst[i] = src[i];
    } else if (@intFromPtr(dst) > @intFromPtr(src)) {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            dst[i] = src[i];
        }
    }
    return dst;
}

export fn memset(dst: [*]u8, val: c_int, n: usize) callconv(.c) [*]u8 {
    @memset(dst[0..n], @truncate(@as(c_uint, @bitCast(val))));
    return dst;
}

export fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
    }
    return 0;
}

export fn memchr(s: [*]const u8, c: c_int, n: usize) callconv(.c) ?[*]const u8 {
    const needle: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (s[i] == needle) return s + i;
    }
    return null;
}

export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    return std.mem.len(s);
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] == b[i] and a[i] != 0) : (i += 1) {}
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
        if (a[i] == 0) return 0;
    }
    return 0;
}

// Lua doesn't set a locale, so byte-order comparison is what "the
// current locale" (the C default, "C") means here.
export fn strcoll(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    return strcmp(a, b);
}

export fn strcpy(dst: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        dst[i] = src[i];
        if (src[i] == 0) break;
    }
    return dst;
}

export fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    const needle: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == needle) return @ptrCast(s + i);
        if (s[i] == 0) return null;
    }
}

export fn strrchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    const needle: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var last: ?[*:0]const u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == needle) last = @ptrCast(s + i);
        if (s[i] == 0) break;
    }
    return last;
}

export fn strstr(hay: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const hlen = std.mem.len(hay);
    const nlen = std.mem.len(needle);
    if (nlen == 0) return hay;
    if (nlen > hlen) return null;
    var i: usize = 0;
    while (i <= hlen - nlen) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + nlen], needle[0..nlen])) return @ptrCast(hay + i);
    }
    return null;
}

export fn strpbrk(s: [*:0]const u8, accept: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (accept[j] != 0) : (j += 1) {
            if (s[i] == accept[j]) return @ptrCast(s + i);
        }
    }
    return null;
}

export fn strspn(s: [*:0]const u8, accept: [*:0]const u8) callconv(.c) usize {
    var i: usize = 0;
    outer: while (s[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (accept[j] != 0) : (j += 1) {
            if (s[i] == accept[j]) continue :outer;
        }
        break;
    }
    return i;
}

// ---- ctype.h (ASCII only — Lua never sets a non-"C" locale) -----------

export fn isdigit(c: c_int) callconv(.c) c_int {
    return boolToInt(c >= '0' and c <= '9');
}
export fn isalpha(c: c_int) callconv(.c) c_int {
    return boolToInt((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'));
}
export fn isalnum(c: c_int) callconv(.c) c_int {
    return boolToInt(isalpha(c) != 0 or isdigit(c) != 0);
}
export fn isspace(c: c_int) callconv(.c) c_int {
    return boolToInt(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c);
}
export fn iscntrl(c: c_int) callconv(.c) c_int {
    return boolToInt((c >= 0 and c < 0x20) or c == 0x7f);
}
export fn ispunct(c: c_int) callconv(.c) c_int {
    return boolToInt(c >= 0x21 and c <= 0x7e and isalnum(c) == 0);
}
export fn isupper(c: c_int) callconv(.c) c_int {
    return boolToInt(c >= 'A' and c <= 'Z');
}
export fn islower(c: c_int) callconv(.c) c_int {
    return boolToInt(c >= 'a' and c <= 'z');
}
export fn isxdigit(c: c_int) callconv(.c) c_int {
    return boolToInt(isdigit(c) != 0 or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'));
}
export fn isgraph(c: c_int) callconv(.c) c_int {
    return boolToInt(c > ' ' and c < 0x7f);
}
export fn toupper(c: c_int) callconv(.c) c_int {
    return if (islower(c) != 0) c - ('a' - 'A') else c;
}
export fn tolower(c: c_int) callconv(.c) c_int {
    return if (isupper(c) != 0) c + ('a' - 'A') else c;
}
fn boolToInt(b: bool) c_int {
    return if (b) 1 else 0;
}

// ---- math.h -------------------------------------------------------------
// Lua's numbers are `double` (LUA_NUMBER, no LUA_USE_C89) throughout.

export fn sqrt(x: f64) callconv(.c) f64 {
    return @sqrt(x);
}
export fn fabs(x: f64) callconv(.c) f64 {
    return @abs(x);
}
export fn floor(x: f64) callconv(.c) f64 {
    return @floor(x);
}
export fn ceil(x: f64) callconv(.c) f64 {
    return @ceil(x);
}
export fn fmod(x: f64, y: f64) callconv(.c) f64 {
    return @rem(x, y);
}
export fn pow(x: f64, y: f64) callconv(.c) f64 {
    return std.math.pow(f64, x, y);
}
export fn exp(x: f64) callconv(.c) f64 {
    return @exp(x);
}
export fn log(x: f64) callconv(.c) f64 {
    return @log(x);
}
export fn log2(x: f64) callconv(.c) f64 {
    return @log2(x);
}
export fn log10(x: f64) callconv(.c) f64 {
    return @log10(x);
}
export fn sin(x: f64) callconv(.c) f64 {
    return @sin(x);
}
export fn cos(x: f64) callconv(.c) f64 {
    return @cos(x);
}
export fn tan(x: f64) callconv(.c) f64 {
    return std.math.tan(x);
}
export fn asin(x: f64) callconv(.c) f64 {
    return std.math.asin(x);
}
export fn acos(x: f64) callconv(.c) f64 {
    return std.math.acos(x);
}
export fn atan(x: f64) callconv(.c) f64 {
    return std.math.atan(x);
}
export fn atan2(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}
export fn ldexp(x: f64, exp_: c_int) callconv(.c) f64 {
    return std.math.ldexp(x, exp_);
}
export fn frexp(x: f64, exp_out: *c_int) callconv(.c) f64 {
    const r = std.math.frexp(x);
    exp_out.* = r.exponent;
    return r.significand;
}
export fn modf(x: f64, int_part: *f64) callconv(.c) f64 {
    const ip = @trunc(x);
    int_part.* = ip;
    return x - ip;
}

// ---- strtod: only ever reached (lobject.c's l_str2dloc, via the
// lua_str2number macro) for plain decimal numerals — Lua pre-filters and
// handles hex floats ("0x1p3") and "inf"/"nan" itself before falling
// back to the real strtod (lobject.c's l_str2d), so this doesn't need to
// parse either. No errno/ERANGE signaling: nothing in lobject.c checks it.

export fn strtod(s: [*:0]const u8, endptr_out: ?*?[*:0]const u8) callconv(.c) f64 {
    var i: usize = 0;
    while (isSpace(s[i])) i += 1;
    var neg = false;
    if (s[i] == '+' or s[i] == '-') {
        neg = s[i] == '-';
        i += 1;
    }
    var mantissa: u64 = 0;
    var mantissa_digits: u32 = 0;
    var any_digits = false;
    var exp_adjust: i32 = 0;
    while (s[i] >= '0' and s[i] <= '9') : (i += 1) {
        any_digits = true;
        if (mantissa_digits < 19) {
            mantissa = mantissa * 10 + (s[i] - '0');
            mantissa_digits += 1;
        } else exp_adjust += 1;
    }
    if (s[i] == '.') {
        i += 1;
        while (s[i] >= '0' and s[i] <= '9') : (i += 1) {
            any_digits = true;
            if (mantissa_digits < 19) {
                mantissa = mantissa * 10 + (s[i] - '0');
                mantissa_digits += 1;
                exp_adjust -= 1;
            }
        }
    }
    if (!any_digits) {
        if (endptr_out) |eo| eo.* = s;
        return 0;
    }
    var exp10: i32 = exp_adjust;
    if (s[i] == 'e' or s[i] == 'E') {
        var j = i + 1;
        var eneg = false;
        if (s[j] == '+' or s[j] == '-') {
            eneg = s[j] == '-';
            j += 1;
        }
        if (s[j] >= '0' and s[j] <= '9') {
            var e: i32 = 0;
            while (s[j] >= '0' and s[j] <= '9') : (j += 1) e = e * 10 + (s[j] - '0');
            i = j;
            exp10 += if (eneg) -e else e;
        }
    }
    var result: f64 = @floatFromInt(mantissa);
    result *= pow(10, @floatFromInt(exp10));
    if (neg) result = -result;
    if (endptr_out) |eo| eo.* = s + i;
    return result;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

// ---- test helpers ------------------------------------------------------
//
// `std.testing` doesn't compile for wasm32-freestanding on this toolchain
// (it reaches std.Io.Threaded, which reaches posix) and these tests run on
// the real target on purpose — see tools/wasm-test-runner.zig and B27 in
// spec/troubleshooting.md. These are the three shapes the tests below need.

fn expect(ok: bool) !void {
    if (!ok) return error.TestFailed;
}

fn expectStr(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) return error.TestFailed;
}

fn expectNear(expected: f64, actual: f64, tolerance: f64) !void {
    const diff = if (actual > expected) actual - expected else expected - actual;
    if (!(diff <= tolerance)) return error.TestFailed;
}

test strtod {
    const t = struct {
        fn run(s: [:0]const u8) f64 {
            var end: ?[*:0]const u8 = null;
            return strtod(s.ptr, &end);
        }
    };
    try expectNear(3.14, t.run("3.14"), 1e-12);
    try expectNear(-5, t.run("-5"), 1e-12);
    try expectNear(1230.0, t.run("1.23e3"), 1e-9);
    try expectNear(0.5, t.run(".5"), 1e-12);
    try expectNear(5.0, t.run("5."), 1e-12);
}

// ---- snprintf: lstrlib.c's `l_sprintf` macro (luaconf.h) always resolves
// to this. Every call site in lstrlib.c hands it exactly one already-
// isolated conversion (str_format extracts one "%..." specifier at a
// time before calling it — see getformat/checkformat), so this only ever
// needs to handle a single-conversion format string, not general printf.
// Argument types (luaconf.h's LUAI_UACINT/LUAI_UACNUMBER, and lstrlib.c's
// explicit casts): `long long` for d/i/u/o/x/X where the format came from
// addlenmod, which inserts LUA_INTEGER_FRMLEN ("ll"); plain `int` where
// lstrlib.c writes the format by hand — "\%d"/"\%03d" for a control
// character in `string.format("%q", s)` and num2straux's "p%+d" exponent
// suffix — and for %c. `double` for f/e/E/g/G, `const char *` for %s,
// `const void *` for %p. Both integer widths really occur, so the length
// modifier is read, not skipped (B27).

const PrintfSink = struct {
    buf: [*]u8,
    cap: usize,
    len: usize = 0,
    total: usize = 0,

    fn putByte(self: *PrintfSink, ch: u8) void {
        if (self.len < self.cap) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
        self.total += 1;
    }
    fn putStr(self: *PrintfSink, s: []const u8) void {
        for (s) |ch| self.putByte(ch);
    }
    fn putN(self: *PrintfSink, ch: u8, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.putByte(ch);
    }
};

// Writes `digits` (unsigned, no sign) with `prefix` (sign or "0x"/"0")
// glued on before any zero-padding, so "-0003" and "0x0003" pad
// correctly, matching C's semantics for the '0' flag.
fn printfEmit(sink: *PrintfSink, prefix: []const u8, digits: []const u8, width: usize, left: bool, zero: bool) void {
    const total_len = prefix.len + digits.len;
    if (total_len >= width) {
        sink.putStr(prefix);
        sink.putStr(digits);
        return;
    }
    const pad = width - total_len;
    if (left) {
        sink.putStr(prefix);
        sink.putStr(digits);
        sink.putN(' ', pad);
    } else if (zero) {
        sink.putStr(prefix);
        sink.putN('0', pad);
        sink.putStr(digits);
    } else {
        sink.putN(' ', pad);
        sink.putStr(prefix);
        sink.putStr(digits);
    }
}

fn printfUint(buf: []u8, value: u64, base: u8, upper: bool) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    const table = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var i: usize = buf.len;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = table[@as(usize, @intCast(v % base))];
        v /= base;
    }
    return buf[i..];
}

fn printfPadZeros(buf: []u8, digits: []const u8, precision: usize) []const u8 {
    if (digits.len >= precision) return digits;
    const zeros = precision - digits.len;
    var tmp: [32]u8 = undefined;
    @memset(tmp[0..zeros], '0');
    @memcpy(tmp[zeros..][0..digits.len], digits);
    @memcpy(buf[0 .. zeros + digits.len], tmp[0 .. zeros + digits.len]);
    return buf[0 .. zeros + digits.len];
}

fn printfInt(sink: *PrintfSink, value: i64, width: usize, precision: i32, left: bool, zero: bool, plus: bool, space: bool) void {
    var buf: [32]u8 = undefined;
    const neg = value < 0;
    const mag: u64 = if (neg) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    var digits = printfUint(&buf, mag, 10, false);
    if (mag == 0 and precision == 0) digits = buf[0..0];
    if (precision >= 0) digits = printfPadZeros(&buf, digits, @intCast(precision));
    var sign_buf: [1]u8 = undefined;
    var prefix: []const u8 = &.{};
    if (neg) {
        sign_buf[0] = '-';
        prefix = sign_buf[0..1];
    } else if (plus) {
        sign_buf[0] = '+';
        prefix = sign_buf[0..1];
    } else if (space) {
        sign_buf[0] = ' ';
        prefix = sign_buf[0..1];
    }
    // A given precision suppresses '0' padding for integer conversions (C99 7.21.6.1p6).
    printfEmit(sink, prefix, digits, width, left, zero and precision < 0);
}

fn printfUnsigned(sink: *PrintfSink, value: u64, base: u8, upper: bool, alt: bool, width: usize, precision: i32, left: bool, zero: bool) void {
    var buf: [32]u8 = undefined;
    var digits = printfUint(&buf, value, base, upper);
    if (value == 0 and precision == 0) digits = buf[0..0];
    if (precision >= 0) digits = printfPadZeros(&buf, digits, @intCast(precision));
    var prefix: []const u8 = &.{};
    if (alt and base == 16 and value != 0) prefix = if (upper) "0X" else "0x";
    if (alt and base == 8 and (digits.len == 0 or digits[0] != '0')) prefix = "0";
    printfEmit(sink, prefix, digits, width, left, zero and precision < 0);
}

const PrintfFloatKind = enum { f, e, g };

const LengthModifier = enum { none, l, ll };

fn printfStripTrailingZeros(s: []u8) []u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

// ---- exact decimal conversion -----------------------------------------
//
// C's printf converts the *exact* value of a double and rounds that to the
// requested precision, ties to even. Zig's std.fmt.float.render rounds the
// shortest decimal that round-trips back to the same double instead, which
// is a different number: %.2f of 1.005 is 1.01 there and 1.00 in C,
// because the double spelled 1.005 is really 1.00499999999999989342 (B27).
//
// Doing it exactly needs neither bignum division nor a binary bignum.
// Every finite double is m × 2^e with m < 2^53. For e >= 0 the value is
// the integer m << e; for e < 0 it is m / 2^k, and m / 2^k = m × 5^k /
// 10^k — so the exact digits are those of m × 5^k with the point k places
// from the right. Both reduce to multiplying a decimal digit array by 2 or
// by 5, repeatedly.
//
// Cost is bounded by the exponent, not by the requested precision: a
// denormal (k = 1074) takes ~1074 passes over ~770 digits, an ordinary
// value like 3.14 about fifty passes over seventeen.

// 2^53 × 5^1074 has 767 digits; 2^53 × 2^971 has 309.
const max_exact_digits = 780;

const Exact = struct {
    /// One decimal digit (0-9) per byte, least significant first.
    digits: [max_exact_digits]u8 = undefined,
    len: usize = 0,
    /// How many of the low digits fall after the decimal point: the value
    /// is `digits` read as an integer, divided by 10^point.
    point: usize = 0,

    fn digitAt(self: *const Exact, index: usize) u8 {
        return if (index < self.len) self.digits[index] else 0;
    }

    fn mul(self: *Exact, factor: u8) void {
        var carry: u32 = 0;
        for (self.digits[0..self.len]) |*digit| {
            const v = @as(u32, digit.*) * factor + carry;
            digit.* = @intCast(v % 10);
            carry = v / 10;
        }
        while (carry > 0) {
            self.digits[self.len] = @intCast(carry % 10);
            self.len += 1;
            carry /= 10;
        }
    }

    /// Index of the most significant non-zero digit; null when the value
    /// is zero.
    fn msd(self: *const Exact) ?usize {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            if (self.digits[i] != 0) return i;
        }
        return null;
    }

    fn addOneAt(self: *Exact, index: usize) void {
        while (index >= self.len) {
            self.digits[self.len] = 0;
            self.len += 1;
        }
        var i = index;
        while (self.digits[i] == 9) {
            self.digits[i] = 0;
            i += 1;
            if (i == self.len) {
                self.digits[i] = 1;
                self.len += 1;
                return;
            }
        }
        self.digits[i] += 1;
    }

    /// Drops every digit below `keep_from`, rounding what's left to
    /// nearest and, on an exact tie, to even — the rule C follows.
    fn roundAt(self: *Exact, keep_from: usize) void {
        if (keep_from == 0) return;
        const first_dropped = self.digitAt(keep_from - 1);
        var round_up = first_dropped > 5;
        if (first_dropped == 5) {
            var rest_nonzero = false;
            var i: usize = 0;
            while (i + 1 < keep_from) : (i += 1) {
                if (self.digitAt(i) != 0) {
                    rest_nonzero = true;
                    break;
                }
            }
            round_up = rest_nonzero or (self.digitAt(keep_from) & 1) == 1;
        }
        var i: usize = 0;
        while (i < keep_from and i < self.len) : (i += 1) self.digits[i] = 0;
        if (round_up) self.addOneAt(keep_from);
    }
};

fn exactFromF64(value: f64) Exact {
    var out: Exact = .{};
    const bits: u64 = @bitCast(value);
    const biased: u32 = @intCast((bits >> 52) & 0x7ff);
    const frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
    // Denormals carry no implicit leading bit and share the smallest
    // exponent; everything else does and doesn't.
    const m: u64 = if (biased == 0) frac else frac | (@as(u64, 1) << 52);
    const exp2: i32 = if (biased == 0) -1074 else @as(i32, @intCast(biased)) - 1075;

    if (m == 0) {
        out.digits[0] = 0;
        out.len = 1;
        return out;
    }
    var v = m;
    while (v > 0) : (v /= 10) {
        out.digits[out.len] = @intCast(v % 10);
        out.len += 1;
    }
    if (exp2 > 0) {
        var i: i32 = 0;
        while (i < exp2) : (i += 1) out.mul(2);
    } else if (exp2 < 0) {
        const k: usize = @intCast(-exp2);
        var i: usize = 0;
        while (i < k) : (i += 1) out.mul(5);
        out.point = k;
    }
    return out;
}

/// The digits C's %f writes for a non-negative finite `value`: `precision`
/// of them after the point, exactly rounded. No sign, padding or '#'.
fn renderFixedExact(out: []u8, value: f64, precision: usize) []const u8 {
    var d = exactFromF64(value);
    if (d.point > precision) d.roundAt(d.point - precision);

    var n: usize = 0;
    if (d.len > d.point) {
        var i = d.len;
        while (i > d.point) {
            i -= 1;
            out[n] = '0' + d.digitAt(i);
            n += 1;
        }
    } else {
        out[n] = '0';
        n += 1;
    }
    if (precision > 0) {
        out[n] = '.';
        n += 1;
        var k: usize = 0;
        while (k < precision) : (k += 1) {
            out[n] = if (k < d.point) '0' + d.digitAt(d.point - 1 - k) else '0';
            n += 1;
        }
    }
    return out[0..n];
}

/// The mantissa C's %e writes — one digit, then `precision` more after a
/// point — exactly rounded. `exp10` receives the decimal exponent.
fn renderScientificExact(out: []u8, value: f64, precision: usize, exp10: *i32) []const u8 {
    var d = exactFromF64(value);
    var n: usize = 0;

    const top = d.msd() orelse {
        exp10.* = 0;
        out[n] = '0';
        n += 1;
        if (precision > 0) {
            out[n] = '.';
            n += 1;
            var k: usize = 0;
            while (k < precision) : (k += 1) {
                out[n] = '0';
                n += 1;
            }
        }
        return out[0..n];
    };

    const significant = precision + 1;
    if (top + 1 > significant) d.roundAt(top + 1 - significant);
    // Rounding can carry into a new leading digit (9.99 -> 10.0), so the
    // exponent comes from where the leading digit ended up, not from `top`.
    const lead = d.msd().?;
    exp10.* = @as(i32, @intCast(lead)) - @as(i32, @intCast(d.point));

    out[n] = '0' + d.digitAt(lead);
    n += 1;
    if (precision > 0) {
        out[n] = '.';
        n += 1;
        var k: usize = 1;
        while (k <= precision) : (k += 1) {
            out[n] = if (k <= lead) '0' + d.digitAt(lead - k) else '0';
            n += 1;
        }
    }
    return out[0..n];
}

/// C's exponent field: always signed, always at least two digits.
fn printfAppendExponent(out: []u8, at: usize, exponent: i32, upper: bool) usize {
    var n = at;
    out[n] = if (upper) 'E' else 'e';
    n += 1;
    const negative = exponent < 0;
    out[n] = if (negative) '-' else '+';
    n += 1;
    var digits_buf: [8]u8 = undefined;
    const magnitude: u64 = @intCast(if (negative) -@as(i64, exponent) else @as(i64, exponent));
    const digits = printfUint(&digits_buf, magnitude, 10, false);
    if (digits.len < 2) {
        out[n] = '0';
        n += 1;
    }
    @memcpy(out[n..][0..digits.len], digits);
    return n + digits.len;
}

fn printfFloat(sink: *PrintfSink, value: f64, kind: PrintfFloatKind, precision_in: i32, width: usize, left: bool, zero: bool, plus: bool, space: bool, alt: bool, upper: bool) void {
    // Room for the longest thing C can ask for here: DBL_MAX under %f is
    // 309 integer digits, and lstrlib.c's format checker caps precision at
    // two digits.
    var work: [512]u8 = undefined;
    var scratch: [512]u8 = undefined;
    const negative = std.math.signbit(value);
    const av = @abs(value);

    var prefix_buf: [1]u8 = undefined;
    var prefix: []const u8 = &.{};
    if (negative) {
        prefix_buf[0] = '-';
        prefix = prefix_buf[0..1];
    } else if (plus) {
        prefix_buf[0] = '+';
        prefix = prefix_buf[0..1];
    } else if (space) {
        prefix_buf[0] = ' ';
        prefix = prefix_buf[0..1];
    }

    if (std.math.isNan(value) or std.math.isInf(value)) {
        var body_buf: [3]u8 = undefined;
        @memcpy(&body_buf, if (std.math.isNan(value)) "nan" else "inf");
        if (upper) for (&body_buf) |*c| {
            c.* = std.ascii.toUpper(c.*);
        };
        printfEmit(sink, prefix, &body_buf, width, left, false);
        return;
    }

    switch (kind) {
        .f => {
            const prec: usize = if (precision_in >= 0) @intCast(precision_in) else 6;
            const rendered = renderFixedExact(&scratch, av, prec);
            @memcpy(work[0..rendered.len], rendered);
            var out = work[0..rendered.len];
            // '#' keeps the point even with nothing after it (C99 7.21.6.1p6).
            if (alt and prec == 0) {
                work[out.len] = '.';
                out = work[0 .. out.len + 1];
            }
            printfEmit(sink, prefix, out, width, left, zero);
        },
        .e => {
            const prec: usize = if (precision_in >= 0) @intCast(precision_in) else 6;
            var exponent: i32 = 0;
            const mantissa = renderScientificExact(&scratch, av, prec, &exponent);
            @memcpy(work[0..mantissa.len], mantissa);
            var n = mantissa.len;
            if (alt and prec == 0) {
                work[n] = '.';
                n += 1;
            }
            n = printfAppendExponent(&work, n, exponent, upper);
            printfEmit(sink, prefix, work[0..n], width, left, zero);
        },
        .g => {
            // C picks the form from the exponent the value has *after*
            // rounding to `prec` significant digits, then drops trailing
            // zeros unless '#' asked to keep them.
            var prec: usize = if (precision_in >= 0) @intCast(precision_in) else 6;
            if (prec == 0) prec = 1;
            var exponent: i32 = 0;
            const mantissa = renderScientificExact(&scratch, av, prec - 1, &exponent);

            if (exponent < -4 or exponent >= @as(i32, @intCast(prec))) {
                @memcpy(work[0..mantissa.len], mantissa);
                var m: []u8 = work[0..mantissa.len];
                if (alt) {
                    if (prec == 1) {
                        work[m.len] = '.';
                        m = work[0 .. m.len + 1];
                    }
                } else m = printfStripTrailingZeros(m);
                const n = printfAppendExponent(&work, m.len, exponent, upper);
                printfEmit(sink, prefix, work[0..n], width, left, zero);
            } else {
                const frac: usize = @intCast(@as(i32, @intCast(prec)) - 1 - exponent);
                const rendered = renderFixedExact(&scratch, av, frac);
                @memcpy(work[0..rendered.len], rendered);
                var out: []u8 = work[0..rendered.len];
                if (alt) {
                    if (std.mem.indexOfScalar(u8, out, '.') == null) {
                        work[out.len] = '.';
                        out = work[0 .. out.len + 1];
                    }
                } else out = printfStripTrailingZeros(out);
                printfEmit(sink, prefix, out, width, left, zero);
            }
        },
    }
}

fn vsnprintfImpl(buf: [*]u8, size: usize, fmt: [*:0]const u8, ap: *std.builtin.VaList) c_int {
    var sink = PrintfSink{ .buf = buf, .cap = if (size == 0) 0 else size - 1 };
    var i: usize = 0;
    while (fmt[i] != 0) {
        if (fmt[i] != '%') {
            sink.putByte(fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (fmt[i] == '%') {
            sink.putByte('%');
            i += 1;
            continue;
        }
        var left = false;
        var plus = false;
        var space = false;
        var zero = false;
        var alt = false;
        while (true) : (i += 1) {
            switch (fmt[i]) {
                '-' => left = true,
                '+' => plus = true,
                ' ' => space = true,
                '0' => zero = true,
                '#' => alt = true,
                else => break,
            }
        }
        var width: usize = 0;
        while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) width = width * 10 + (fmt[i] - '0');
        var precision: i32 = -1;
        if (fmt[i] == '.') {
            i += 1;
            precision = 0;
            while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) precision = precision * 10 + (fmt[i] - '0');
        }
        // The width a vararg was written with is the width it must be read
        // with: on wasm32 they sit in a memory buffer, not in registers, so
        // reading a plain `int` as `long long` reads past it (B27). 'h'/'hh'
        // promote to int, 'L' (long double) never reaches this file.
        var lenmod: LengthModifier = .none;
        while (true) : (i += 1) {
            switch (fmt[i]) {
                'l' => lenmod = if (lenmod == .l) .ll else .l,
                'h', 'L' => {},
                else => break,
            }
        }
        const spec = fmt[i];
        i += 1;
        switch (spec) {
            'c' => {
                const v = @cVaArg(ap, c_int);
                const ch: u8 = @truncate(@as(c_uint, @bitCast(v)));
                printfEmit(&sink, &.{}, &[_]u8{ch}, width, left, false);
            },
            'd', 'i' => {
                const v: i64 = switch (lenmod) {
                    .none => @cVaArg(ap, c_int),
                    .l => @cVaArg(ap, c_long),
                    .ll => @cVaArg(ap, c_longlong),
                };
                printfInt(&sink, v, width, precision, left, zero, plus, space);
            },
            'u', 'o', 'x', 'X' => {
                const v: u64 = switch (lenmod) {
                    .none => @cVaArg(ap, c_uint),
                    .l => @cVaArg(ap, c_ulong),
                    .ll => @cVaArg(ap, c_ulonglong),
                };
                const base: u8 = switch (spec) {
                    'o' => 8,
                    'u' => 10,
                    else => 16,
                };
                printfUnsigned(&sink, v, base, spec == 'X', alt, width, precision, left, zero);
            },
            'f', 'F' => {
                const v = @cVaArg(ap, f64);
                printfFloat(&sink, v, .f, precision, width, left, zero, plus, space, alt, spec == 'F');
            },
            'e', 'E' => {
                const v = @cVaArg(ap, f64);
                printfFloat(&sink, v, .e, precision, width, left, zero, plus, space, alt, spec == 'E');
            },
            'g', 'G' => {
                const v = @cVaArg(ap, f64);
                printfFloat(&sink, v, .g, precision, width, left, zero, plus, space, alt, spec == 'G');
            },
            'p' => {
                const v = @cVaArg(ap, ?*anyopaque);
                printfUnsigned(&sink, @intFromPtr(v), 16, false, true, width, -1, left, false);
            },
            's' => {
                const v = @cVaArg(ap, [*:0]const u8);
                var len: usize = 0;
                while (v[len] != 0) : (len += 1) {
                    if (precision >= 0 and len >= @as(usize, @intCast(precision))) break;
                }
                printfEmit(&sink, &.{}, v[0..len], width, left, false);
            },
            else => {},
        }
    }
    if (size > 0) buf[sink.len] = 0;
    return @intCast(sink.total);
}

export fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return vsnprintfImpl(buf, size, fmt, &ap);
}

// lauxlib.c's default panic handler (lua_writestringerror, only reached
// when an error escapes every protected call — an aster bug, not normal
// Lua error flow) formats into a scratch buffer and hands it to fwrite,
// same as `print` — see stdio.h's header comment on why that's a no-op
// today rather than routed to host.log.
export fn fprintf(f: ?*anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var buf: [1024]u8 = undefined;
    const n = vsnprintfImpl(&buf, buf.len, fmt, &ap);
    if (n <= 0) return n;
    return @intCast(fwrite(&buf, 1, @intCast(n), f));
}

test "snprintf: the shapes lstrlib.c actually asks for" {
    var buf: [128]u8 = undefined;
    var n = snprintf(&buf, buf.len, "%lld", @as(c_longlong, -42));
    try expectStr("-42", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "0x%llx", @as(c_longlong, 255));
    try expectStr("0xff", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%s", @as([*:0]const u8, "hello"));
    try expectStr("hello", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%c", @as(c_int, 'A'));
    try expectStr("A", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, LUA_NUMBER_FMT, @as(f64, 3.14));
    try expectStr("3.14", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "p%+d", @as(c_int, 3));
    try expectStr("p+3", buf[0..@intCast(n)]);

    // num2straux's inf/nan fallback and 0-value case both use "%.14g".
    n = snprintf(&buf, buf.len, LUA_NUMBER_FMT, std.math.inf(f64));
    try expectStr("inf", buf[0..@intCast(n)]);
}
const LUA_NUMBER_FMT = "%.14g";

// lstrlib.c doesn't only build format strings through addlenmod (which
// inserts LUA_INTEGER_FRMLEN, "ll"): `string.format("%q", s)` escapes a
// control character with a hand-written "\\%d"/"\\%03d" and a plain
// `int` (lstrlib.c:1132/1134), and num2straux's exponent suffix does the
// same with "p%+d" (lstrlib.c:1049). On wasm32 a vararg's width is the
// width it was written with, so reading these as `long long` reads past
// the argument — the shape this file's own header comment used to claim
// couldn't occur.
test "snprintf: %d with a plain int, as string.format(\"%q\") passes it" {
    var buf: [128]u8 = undefined;
    var n = snprintf(&buf, buf.len, "\\%d", @as(c_int, 7));
    try expectStr("\\7", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "\\%03d", @as(c_int, 9));
    try expectStr("\\009", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "p%+d", @as(c_int, -3));
    try expectStr("p-3", buf[0..@intCast(n)]);
}

// C's %g and %G differ only in the case of the exponent letter, never in
// which digits survive.
test "snprintf: %G strips trailing zeros the way %g does" {
    var buf: [128]u8 = undefined;
    var n = snprintf(&buf, buf.len, "%G", @as(f64, 1e15));
    try expectStr("1E+15", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%G", @as(f64, 1.5e-5));
    try expectStr("1.5E-05", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%g", @as(f64, 1e15));
    try expectStr("1e+15", buf[0..@intCast(n)]);
}

// '#' keeps the decimal point even when no digits follow it (C99
// 7.21.6.1p6), for %g as well as %f.
test "snprintf: %#g keeps the decimal point" {
    var buf: [128]u8 = undefined;
    var n = snprintf(&buf, buf.len, "%#g", @as(f64, 100000.0));
    try expectStr("100000.", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%#.0f", @as(f64, 3.0));
    try expectStr("3.", buf[0..@intCast(n)]);
}

// The whole point of converting the exact binary value rather than the
// shortest decimal that round-trips: these are the cases where the two
// disagree, and C prints the left-hand column (B27).
test "snprintf: fixed precision rounds the exact value, ties to even" {
    var buf: [128]u8 = undefined;
    // 1.005 is really 1.00499999999999989342, so it rounds down.
    var n = snprintf(&buf, buf.len, "%.2f", @as(f64, 1.005));
    try expectStr("1.00", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%.2f", @as(f64, 2.675));
    try expectStr("2.67", buf[0..@intCast(n)]);

    // Exact ties go to even, which is what C's default rounding mode does.
    n = snprintf(&buf, buf.len, "%.0f", @as(f64, 0.5));
    try expectStr("0", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%.0f", @as(f64, 1.5));
    try expectStr("2", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%.0f", @as(f64, 2.5));
    try expectStr("2", buf[0..@intCast(n)]);

    n = snprintf(&buf, buf.len, "%.2f", @as(f64, 0.125));
    try expectStr("0.12", buf[0..@intCast(n)]);
}

test "snprintf: significant digits past the shortest round-trip" {
    var buf: [512]u8 = undefined;
    var n = snprintf(&buf, buf.len, "%.17g", @as(f64, 0.1));
    try expectStr("0.10000000000000001", buf[0..@intCast(n)]);

    // The smallest denormal, whose exact value is nothing like "5e-324".
    n = snprintf(&buf, buf.len, "%g", @as(f64, 5e-324));
    try expectStr("4.94066e-324", buf[0..@intCast(n)]);

    // tostring()'s own format, unaffected either way — kept so a future
    // change to the conversion can't quietly move it.
    n = snprintf(&buf, buf.len, LUA_NUMBER_FMT, @as(f64, 0.1));
    try expectStr("0.1", buf[0..@intCast(n)]);
}

test "snprintf: %f writes the whole exact integer, not a rounded stand-in" {
    var buf: [512]u8 = undefined;
    const n = snprintf(&buf, buf.len, "%.0f", @as(f64, 1e100));
    try expectStr(
        "10000000000000000159028911097599180468360808563945281389781327557747838772170381060813469985856815104",
        buf[0..@intCast(n)],
    );
}

// ---- setjmp/longjmp: declared in vendor/setjmp.h, implemented in
// vendor/rt.c (__wasm_setjmp/__wasm_longjmp) — nothing to add here.

// ---- misc: assert/abort, and "randomness" sources that are only ever
// used to seed table.sort's pivot against algorithmic-complexity attacks
// (ltablib.c's l_randomizePivot) or the string-hash seed (lstate.c) —
// not a security boundary (spec/architecture.md §1.6), so a monotonic
// counter is a fine source of "different every call".

export fn abort() callconv(.c) noreturn {
    @trap();
}

// loadlib.c's luaopen_package calls setpath() unconditionally at Lua
// state init (via getenv, looking for LUA_PATH/LUA_CPATH overrides);
// src/host/lua.zig immediately overwrites package.path afterwards
// regardless, and there's no OS environment to read on this backend —
// "no override configured" (NULL) is simply correct, not a stub.
export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    _ = name;
    return null;
}

export fn abs(x: c_int) callconv(.c) c_int {
    return @intCast(@abs(x));
}

var clock_counter: u64 = 0;

export fn clock() callconv(.c) i64 {
    clock_counter +%= 1;
    return @bitCast(clock_counter);
}

export fn time(out: ?*i64) callconv(.c) i64 {
    clock_counter +%= 1;
    const t: i64 = @bitCast(clock_counter);
    if (out) |o| o.* = t;
    return t;
}

// ---- stdio.h: only reachable through luaL_loadfilex, which the wasm
// backend never calls (see this file's header comment) — always fail.

export fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    _ = path;
    _ = mode;
    return null;
}
export fn fclose(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return 0;
}
export fn fread(ptr: ?*anyopaque, size: usize, n: usize, f: ?*anyopaque) callconv(.c) usize {
    _ = ptr;
    _ = size;
    _ = n;
    _ = f;
    return 0;
}
export fn feof(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return 1;
}
export fn ferror(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return 1;
}

var stdin_sentinel: u8 = 0;
var stdout_sentinel: u8 = 0;
var stderr_sentinel: u8 = 0;
export var stdin: ?*anyopaque = &stdin_sentinel;
export var stdout: ?*anyopaque = &stdout_sentinel;
export var stderr: ?*anyopaque = &stderr_sentinel;

export fn freopen(path: [*:0]const u8, mode: [*:0]const u8, f: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = path;
    _ = mode;
    _ = f;
    return null;
}
export fn getc(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return -1; // EOF
}
// No backend routes Lua's `print` through host.log yet (see stdio.h) —
// a silent no-op matches "nothing observably happens" better than a trap.
export fn fwrite(ptr: ?*const anyopaque, size: usize, n: usize, f: ?*anyopaque) callconv(.c) usize {
    _ = ptr;
    _ = f;
    return size * n;
}
export fn fflush(f: ?*anyopaque) callconv(.c) c_int {
    _ = f;
    return 0;
}

// errno/strerror: referenced inside lauxlib.c's luaL_fileresult/
// luaL_execresult (POSIX file/process error reporting) — dead code on
// this backend for the same reason as the stdio stubs above, but the
// symbols must still resolve for the link to succeed.

export var errno: c_int = 0;

export fn strerror(errnum: c_int) callconv(.c) [*:0]const u8 {
    _ = errnum;
    return "error";
}
