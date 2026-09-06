const std = @import("std");
const builtin = @import("builtin");

// `aster`, `aster-conformance` and the unit-test binary are all the same
// core (src/main.zig, the Lua C sources, SDL3, the embedded font) with
// different build_options — this is the one place in the project where a
// shared helper actually saves more than it costs.
fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
}

fn configureCore(
    step: *std.Build.Step.Compile,
    b: *std.Build,
    lua_sources: []const []const u8,
    build_options: *std.Build.Step.Options,
    font_mod: *std.Build.Module,
) void {
    step.root_module.addIncludePath(b.path("libs/lua-5.4/src"));
    step.root_module.addCSourceFiles(.{ .files = lua_sources, .flags = &.{"-std=c99"} });
    step.root_module.linkSystemLibrary("SDL3", .{});
    step.root_module.addOptions("build_options", build_options);
    step.root_module.addImport("embedded_font", font_mod);
}

pub fn build(b: *std.Build) void {
    // Pin the exact Zig version so a mismatch can't silently produce a
    // different binary between a contributor's machine and CI.
    const pinned = std.mem.trim(u8, @embedFile(".zig-version"), " \n\r");
    const expected = std.SemanticVersion.parse(pinned) catch {
        std.debug.print("build: cannot parse .zig-version '{s}'\n", .{pinned});
        std.process.exit(1);
    };
    const current = builtin.zig_version;
    if (current.major != expected.major or current.minor != expected.minor or current.patch != expected.patch) {
        std.debug.print("build: this project requires Zig {s}, running {d}.{d}.{d}\n", .{
            pinned, current.major, current.minor, current.patch,
        });
        std.process.exit(1);
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lua_sources = [_][]const u8{
        "libs/lua-5.4/src/lapi.c",
        "libs/lua-5.4/src/lauxlib.c",
        "libs/lua-5.4/src/lbaselib.c",
        "libs/lua-5.4/src/lcode.c",
        "libs/lua-5.4/src/lcorolib.c",
        "libs/lua-5.4/src/lctype.c",
        "libs/lua-5.4/src/ldebug.c",
        "libs/lua-5.4/src/ldo.c",
        "libs/lua-5.4/src/ldump.c",
        "libs/lua-5.4/src/lfunc.c",
        "libs/lua-5.4/src/lgc.c",
        "libs/lua-5.4/src/llex.c",
        "libs/lua-5.4/src/loadlib.c",
        "libs/lua-5.4/src/lmathlib.c",
        "libs/lua-5.4/src/lmem.c",
        "libs/lua-5.4/src/lobject.c",
        "libs/lua-5.4/src/lopcodes.c",
        "libs/lua-5.4/src/lparser.c",
        "libs/lua-5.4/src/lstate.c",
        "libs/lua-5.4/src/lstring.c",
        "libs/lua-5.4/src/lstrlib.c",
        "libs/lua-5.4/src/ltable.c",
        "libs/lua-5.4/src/ltablib.c",
        "libs/lua-5.4/src/ltm.c",
        "libs/lua-5.4/src/lundump.c",
        "libs/lua-5.4/src/lutf8lib.c",
        "libs/lua-5.4/src/lvm.c",
        "libs/lua-5.4/src/lzio.c",
    };

    const release_options = b.addOptions();
    release_options.addOption(bool, "conformance", false);

    // A one-line module rooted at assets/ itself (ADR-006's font.ttf, plus
    // whatever else lands there later) — see B12 in spec/troubleshooting.md.
    const font_mod = b.createModule(.{ .root_source_file = b.path("assets/font.zig") });

    const exe = b.addExecutable(.{ .name = "aster", .root_module = coreModule(b, target, optimize) });
    configureCore(exe, b, &lua_sources, release_options, font_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run aster");
    run_step.dependOn(&run_cmd.step);

    // A separate binary, never the one anyone ships: this is the only
    // build that has host._inject (spec/host-contract.md caps.inject),
    // used by spec/conformance/04_events.lua and 07_resize.lua to drive
    // input synthetically. Structurally separate from `aster` so "never in
    // the release binary" can't be a forgotten flag.
    const conformance_options = b.addOptions();
    conformance_options.addOption(bool, "conformance", true);

    const conformance_exe = b.addExecutable(.{ .name = "aster-conformance", .root_module = coreModule(b, target, optimize) });
    configureCore(conformance_exe, b, &lua_sources, conformance_options, font_mod);
    b.installArtifact(conformance_exe);

    const exe_tests = b.addTest(.{ .root_module = coreModule(b, target, optimize) });
    configureCore(exe_tests, b, &lua_sources, release_options, font_mod);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const budget_cmd = b.addSystemCommand(&.{"tools/budget.sh"});

    // spec/architecture.md's "Four rules" 1/2/3, enforced by a script that
    // can fail the build instead of by prose alone (see tools/budget.sh's
    // own header for the same principle applied to the line budget).
    const contract_boundary_cmd = b.addSystemCommand(&.{"tools/check-contract-boundary.sh"});
    const renderer_ignorance_cmd = b.addSystemCommand(&.{"tools/check-renderer-ignorance.sh"});

    // The host contract is only enforced if something can fail the build
    // over it, not just prose describing it. This needs `aster-conformance`
    // on disk, so depend on the install step rather than the exe artifacts
    // directly.
    const conformance_cmd = b.addSystemCommand(&.{"tools/conformance.sh"});
    conformance_cmd.step.dependOn(b.getInstallStep());

    // tests/ui/ (spec/architecture.md's "Reload preserves state" and
    // "Windows and apps" sections): Lua modules against the fake
    // host, not a backend against the contract — needs nothing built, just
    // a system Lua 5.4.
    const ui_tests_cmd = b.addSystemCommand(&.{"tools/ui-tests.sh"});

    const test_step = b.step("test", "Run unit tests, the core line budget, the host-contract conformance suite, and the tests/ui/ suite");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&budget_cmd.step);
    test_step.dependOn(&contract_boundary_cmd.step);
    test_step.dependOn(&renderer_ignorance_cmd.step);
    test_step.dependOn(&conformance_cmd.step);
    test_step.dependOn(&ui_tests_cmd.step);
}
