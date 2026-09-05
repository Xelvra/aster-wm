const std = @import("std");
const lua = @import("host/lua.zig");
const fs = @import("host/fs.zig");
const sdl_backend = @import("backends/sdl/backend.zig");

test {
    std.testing.refAllDecls(@import("render/renderer.zig"));
    _ = @import("host/bindings.zig");
}

// The "Juicy Main" entry point (Zig 0.16's Io interface): the application
// picks its Io/allocator once, here, and hands them down — nothing further
// in should construct its own std.Io.Threaded or DebugAllocator.
pub fn main(init: std.process.Init) !void {
    fs.setIo(init.io);

    var sdl = try sdl_backend.Sdl.init(init.gpa, init.environ_map, "aster", 1024, 768);
    defer sdl.deinit();

    var state = try lua.State.init(init.gpa, sdl.backend());
    defer state.deinit();

    // spec/conformance/ mode: `aster-conformance path/to/test.lua` loads
    // and runs the script directly against the real host.* table (this
    // binary only, per build.zig — the release `aster` has no
    // host._inject and this branch is dead weight there but harmless).
    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]
    if (args.next()) |script_path| {
        std.process.exit(try state.runScript(script_path));
    }

    try state.boot();

    var buf: [16]u8 = undefined;
    while (true) {
        const status = try state.frame(&buf);
        if (std.mem.eql(u8, status, "quit")) break;
        // "idle": nothing changed, so block instead of spinning (see B6 in
        // spec/troubleshooting.md and ADR-002). The ~1000ms timeout matches
        // host-contract.md's "or for about a second, so the clock keeps
        // ticking" so a time-based Lua widget (e.g. a clock) still updates
        // even with no input.
        if (std.mem.eql(u8, status, "idle")) sdl.idleWait(1000);
    }

    try state.shutdown();
}
