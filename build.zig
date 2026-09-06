const std = @import("std");
const builtin = @import("builtin");

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

    const exe = b.addExecutable(.{
        .name = "aster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addIncludePath(b.path("libs/lua-5.4/src"));
    exe.root_module.addCSourceFiles(.{
        .files = &lua_sources,
        .flags = &.{"-std=c99"},
    });
    exe.root_module.linkSystemLibrary("SDL3", .{});
    exe.root_module.addOptions("build_options", release_options);
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
    // the release binary" (§9.4) can't be a forgotten flag.
    const conformance_options = b.addOptions();
    conformance_options.addOption(bool, "conformance", true);

    const conformance_exe = b.addExecutable(.{
        .name = "aster-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    conformance_exe.root_module.addIncludePath(b.path("libs/lua-5.4/src"));
    conformance_exe.root_module.addCSourceFiles(.{
        .files = &lua_sources,
        .flags = &.{"-std=c99"},
    });
    conformance_exe.root_module.linkSystemLibrary("SDL3", .{});
    conformance_exe.root_module.addOptions("build_options", conformance_options);
    b.installArtifact(conformance_exe);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe_tests.root_module.addIncludePath(b.path("libs/lua-5.4/src"));
    exe_tests.root_module.addCSourceFiles(.{
        .files = &lua_sources,
        .flags = &.{"-std=c99"},
    });
    exe_tests.root_module.linkSystemLibrary("SDL3", .{});
    exe_tests.root_module.addOptions("build_options", release_options);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const budget_cmd = b.addSystemCommand(&.{"tools/budget.sh"});

    // The host contract is only enforced if something can fail the build
    // over it (see the project's root rules: "claim se dokládá mechanismem,
    // který ho může rozbít build, ne prózou"). This needs `aster-conformance`
    // on disk, so depend on the install step rather than the exe artifacts
    // directly.
    const conformance_cmd = b.addSystemCommand(&.{"tools/conformance.sh"});
    conformance_cmd.step.dependOn(b.getInstallStep());

    // tests/ui/ (spec/architecture.md §9.1): Lua modules against the fake
    // host, not a backend against the contract — needs nothing built, just
    // a system Lua 5.4.
    const ui_tests_cmd = b.addSystemCommand(&.{"tools/ui-tests.sh"});

    const test_step = b.step("test", "Run unit tests, the core line budget, the host-contract conformance suite, and the tests/ui/ suite");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&budget_cmd.step);
    test_step.dependOn(&conformance_cmd.step);
    test_step.dependOn(&ui_tests_cmd.step);
}
