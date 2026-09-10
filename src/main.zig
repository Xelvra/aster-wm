const std = @import("std");
const lua = @import("host/lua.zig");
const fs = @import("host/fs.zig");
const sdl_backend = @import("backends/sdl/backend.zig");
const renderer = @import("render/renderer.zig");

test {
    std.testing.refAllDecls(@import("render/renderer.zig"));
    std.testing.refAllDecls(@import("render/ttf.zig"));
    std.testing.refAllDecls(@import("render/font.zig"));
    _ = @import("host/bindings.zig");
    // pub fn main() is never called by a test build (the test runner
    // supplies its own entry point), so anything only reachable from
    // main()'s body — like constructing sdl_backend.Sdl — is otherwise
    // never analyzed and its test blocks never discovered.
    _ = @import("backends/sdl/backend.zig");
}

// The "Juicy Main" entry point (Zig 0.16's Io interface): the application
// picks its Io/allocator once, here, and hands them down — nothing further
// in should construct its own std.Io.Threaded or DebugAllocator.
pub fn main(init: std.process.Init) !void {
    fs.setIo(init.io);
    renderer.initFont(init.gpa);
    defer renderer.deinitFont();

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
    // Deferred, not a plain call after the loop: the contract says
    // "aster.shutdown() — once, before the process exits", and a `try
    // state.frame(...)` returning an error below would otherwise skip a
    // plain trailing call entirely.
    defer state.shutdown() catch |err| {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "aster.shutdown() failed: {s}", .{@errorName(err)}) catch "aster.shutdown() failed";
        fs.log(msg);
    };

    // Target spacing between frames that actually redrew ("running", not
    // "idle") — an app whose `tick` returns true every frame (an animation)
    // would otherwise spin main.zig's loop as fast as the CPU allows, with
    // nothing between one state.frame() and the next. See B34 in
    // spec/troubleshooting.md.
    const target_frame_ms: i64 = 1000 / 60;

    var buf: [16]u8 = undefined;
    while (true) {
        const frame_start = fs.nowMs();
        const status = try state.frame(&buf);
        if (std.mem.eql(u8, status, "quit")) break;
        if (std.mem.eql(u8, status, "idle")) {
            // Nothing changed, so block instead of spinning (see B6 in
            // spec/troubleshooting.md and ADR-002). The ~1000ms timeout
            // matches host-contract.md's "or for about a second, so the
            // clock keeps ticking" so a time-based Lua widget (e.g. a
            // clock) still updates even with no input.
            sdl.idleWait(1000);
            continue;
        }
        // "running": pace to ~60fps. idleWait wakes up early the moment an
        // event arrives (it's built on SDL_WaitEventTimeout), so this never
        // adds input latency — it only fills the time a frame would
        // otherwise have spent spinning with nothing to draw.
        const elapsed_ms = fs.nowMs() - frame_start;
        if (elapsed_ms < target_frame_ms) {
            sdl.idleWait(@intCast(target_frame_ms - elapsed_ms));
        }
    }
}
