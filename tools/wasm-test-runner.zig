//! Test runner for the wasm backend's own unit tests (`zig build test`
//! runs these through tools/wasm-tests.js).
//!
//! Zig's default test runner needs a real stdout and `std.Io.Threaded`,
//! neither of which exists on wasm32-freestanding, so the build passes
//! this one instead (`.test_runner = .{ ... .mode = .simple }`). The
//! tests it runs can't use `std.testing` for the same reason — see B27 in
//! spec/troubleshooting.md.
//!
//! A wasm module can't exit with a status or write to a console on its
//! own, so results leave through exports the JS harness reads: run the
//! tests, then ask for the count and the names that failed.

const builtin = @import("builtin");

var failed_names: [4096]u8 = undefined;
var failed_len: usize = 0;

export fn aster_test_count() u32 {
    return @intCast(builtin.test_functions.len);
}

export fn aster_run_tests() u32 {
    var failed: u32 = 0;
    for (builtin.test_functions) |t| {
        t.func() catch {
            failed += 1;
            record(t.name);
        };
    }
    return failed;
}

fn record(name: []const u8) void {
    for (name) |ch| {
        if (failed_len == failed_names.len) return;
        failed_names[failed_len] = ch;
        failed_len += 1;
    }
    if (failed_len < failed_names.len) {
        failed_names[failed_len] = '\n';
        failed_len += 1;
    }
}

export fn aster_failed_names_ptr() [*]const u8 {
    return &failed_names;
}
export fn aster_failed_names_len() usize {
    return failed_len;
}
