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
    // ADR-015: native builds embed the same Lua core the wasm backend
    // already did, as the fallback searcher (src/host/modules.zig,
    // registered LAST there) for a binary running outside its own
    // checkout — see addEmbeddedLua's own comment for why @embedFile needs
    // this module-mapping step at all.
    addEmbeddedLua(b, step.root_module, &embedded_lua);
}

// The wasm backend has no filesystem (ADR-013) and, per ADR-015, every
// other backend needs the same Lua available as a fallback for a binary
// running outside its own checkout — so the Lua core is compiled into
// every binary. @embedFile only reaches files under the directory holding
// its own module's root source file, and lua/, apps/, widgets/, themes/,
// config/ and spec/conformance/ are siblings of src/ — so rather than a path, each
// file is mapped into the module under its repo-relative name and
// @embedFile'd by that name (ziglang/zig#14553: @embedFile resolves
// module-mapped names the same way @import does). Not addEmbedPath, which
// reads like the tool for exactly this and is a no-op for @embedFile on
// Zig 0.16.0 — see B26 in spec/troubleshooting.md.
//
// The names are the paths, so the call sites (src/host/modules.zig,
// src/main_wasm.zig) still read as if they were embedding by path, and an
// @embedFile of a name missing from these lists fails the build with
// FileNotFound. The other direction is silent: a path listed here that
// nothing embeds is just unused.
fn addEmbeddedLua(b: *std.Build, mod: *std.Build.Module, paths: []const []const u8) void {
    for (paths) |path| mod.addAnonymousImport(path, .{ .root_source_file = b.path(path) });
}

const embedded_lua = [_][]const u8{
    "lua/aster/init.lua",
    "lua/aster/input.lua",
    "lua/aster/loop.lua",
    "lua/aster/render.lua",
    "lua/aster/wm.lua",
    "lua/aster/bar.lua",
    "lua/aster/launcher.lua",
    "apps/hello-window.lua",
    "apps/editor.lua",
    "apps/plasma.lua",
    "apps/snake.lua",
    "apps/calculator.lua",
    "apps/theme-switcher.lua",
    "widgets/clock-widget.lua",
    "widgets/workspace-widget.lua",
    "widgets/active-window-widget.lua",
    "widgets/sysmon-widget.lua",
    "widgets/launcher-button.lua",
    "themes/default.lua",
    "themes/nord.lua",
    "themes/catppuccin-mocha.lua",
    "themes/gruvbox.lua",
    // Not a package module (src/host/modules.zig doesn't register it as
    // one) — the config seed ADR-015 writes to a fresh ~/.config/aster/.
    "config/wm.lua",
};

const embedded_conformance = [_][]const u8{
    "spec/conformance/01_info.lua",
    "spec/conformance/02_surface.lua",
    "spec/conformance/03_present.lua",
    "spec/conformance/04_events.lua",
    "spec/conformance/05_time.lua",
    "spec/conformance/06_fs.lua",
    "spec/conformance/07_resize.lua",
};

// ADR-013: the wasm backend targets wasm32-freestanding, not wasm32-wasi
// — no wasi-libc, so none of coreModule/configureCore's SDL3/link_libc
// setup applies. Its own libc (src/backends/wasm/libc.zig) and Lua's
// setjmp/longjmp runtime (src/backends/wasm/vendor/rt.c) both need
// `-mexception-handling -mllvm -wasm-enable-sjlj -funwind-tables=2`
// (ADR-013's Options-considered #2/#5: the exact flags that avoid the
// LLVM codegen bug in Zig's own wasi-libc build) — `-funwind-tables=2`
// specifically has to be a C source flag, not just a target feature,
// which is why this doesn't fold into coreModule's shape at all despite
// looking similar on the surface.
fn wasmTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
    });
}

const wasm_c_flags = [_][]const u8{
    "-std=gnu99",
    "-mexception-handling",
    "-mllvm",
    "-wasm-enable-sjlj",
    "-Xclang",
    "-funwind-tables=2",
    "-Dlua_getlocaledecpoint()=((int)'.')",
    // B23 in spec/troubleshooting.md: Zig's default UBSan instrumentation
    // traps inside lua_newstate on this target specifically.
    "-fno-sanitize=all",
};

// A fresh module every call: `aster-wasm`, `aster-wasm-conformance` and
// the wasm test binary are three Compile steps over the same sources.
fn wasmModule(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    lua_sources: []const []const u8,
    font_mod: *std.Build.Module,
    conformance: bool,
) *std.Build.Module {
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = wasmTarget(b),
        .optimize = optimize,
    });
    wasm_mod.addIncludePath(b.path("src/backends/wasm/vendor"));
    wasm_mod.addIncludePath(b.path("libs/lua-5.4/src"));
    wasm_mod.addCSourceFiles(.{ .files = lua_sources, .flags = &wasm_c_flags });
    wasm_mod.addCSourceFile(.{ .file = b.path("src/backends/wasm/vendor/rt.c"), .flags = &wasm_c_flags });
    wasm_mod.addImport("embedded_font", font_mod);
    addEmbeddedLua(b, wasm_mod, &embedded_lua);
    // Only the conformance build ever @embedFile's these (main_wasm.zig's
    // own comptime guard) — the release aster-wasm binary doesn't carry
    // spec/conformance/'s text.
    if (conformance) addEmbeddedLua(b, wasm_mod, &embedded_conformance);

    const wasm_options = b.addOptions();
    wasm_options.addOption(bool, "conformance", conformance);
    wasm_mod.addOptions("build_options", wasm_options);
    return wasm_mod;
}

fn buildWasm(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    lua_sources: []const []const u8,
    font_mod: *std.Build.Module,
    conformance: bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = if (conformance) "aster-wasm-conformance" else "aster-wasm",
        .root_module = wasmModule(b, optimize, lua_sources, font_mod, conformance),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    return exe;
}

// The wasm backend's unit tests run on the real target, not on a native
// build of the same source: src/backends/wasm/libc.zig exists to satisfy a
// C ABI (varargs, pointer width, alignment) that a host build wouldn't
// exercise — a `%d` reading the wrong vararg width is invisible on x86-64
// and wrong on wasm32. `zig build test` runs the result through
// tools/wasm-tests.js; tools/wasm-test-runner.zig says why neither the
// default test runner nor `std.testing` works on this target.
//
// Rooted at libc.zig rather than main_wasm.zig on purpose: a test build
// compiles the test blocks of every file in the root's import graph, and
// main_wasm.zig reaches src/render/, whose tests do use `std.testing` —
// correctly, since the native test binary is where they run. The two test
// binaries are meant to cover different files, not the same ones twice.
fn buildWasmTests(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .name = "aster-wasm-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/backends/wasm/libc.zig"),
            .target = wasmTarget(b),
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("tools/wasm-test-runner.zig"), .mode = .simple },
    });
    tests.entry = .disabled;
    tests.rdynamic = true;
    return tests;
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

    // M5 (ADR-013): a second backend. `b.installArtifact` below puts it on
    // the default "install" step alongside the native binaries — plain
    // `zig build`/`zig build test` already exercise it, a backend nobody's
    // build ever touches is how ADR-011's fork stays a surprise instead of
    // a decision. `wasm_step` further down is an *additional*, narrower
    // step (no SDL3 needed), not a replacement for this.
    const wasm_exe = buildWasm(b, optimize, &lua_sources, font_mod, false);
    b.installArtifact(wasm_exe);
    const wasm_conformance_exe = buildWasm(b, optimize, &lua_sources, font_mod, true);
    b.installArtifact(wasm_conformance_exe);

    // A narrower target than the default "install" step above: just the
    // wasm artifacts, no SDL3 needed to build them. `.github/workflows/
    // pages.yml` uses this — that job has no SDL3 dev packages installed
    // (ci.yml's job does, for the native build) and doesn't need them.
    const wasm_step = b.step("wasm", "Build only the wasm backend artifacts (no SDL3 needed)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
    wasm_step.dependOn(&b.addInstallArtifact(wasm_conformance_exe, .{}).step);

    const wasm_tests = buildWasmTests(b, optimize);
    const wasm_tests_cmd = b.addSystemCommand(&.{"tools/wasm-tests.sh"});
    wasm_tests_cmd.addFileArg(wasm_tests.getEmittedBin());

    const budget_cmd = b.addSystemCommand(&.{"tools/budget.sh"});

    // spec/architecture.md's "Four rules" 1/2/3, enforced by a script that
    // can fail the build instead of by prose alone (see tools/budget.sh's
    // own header for the same principle applied to the line budget).
    const contract_boundary_cmd = b.addSystemCommand(&.{"tools/check-contract-boundary.sh"});
    const renderer_ignorance_cmd = b.addSystemCommand(&.{"tools/check-renderer-ignorance.sh"});
    // Reads `git ls-files`, so it checks what a reader who CLONED the repo
    // would get, not what happens to sit in the working tree — an untracked
    // doc is missing for everyone but its author, which is the whole failure
    // this guards against (see the script's own header, and ADR-016).
    const dangling_refs_cmd = b.addSystemCommand(&.{"tools/check-no-dangling-refs.sh"});

    // The host contract is only enforced if something can fail the build
    // over it, not just prose describing it. This needs `aster-conformance`
    // and `aster-wasm-conformance` on disk, so depend on the install step
    // rather than the exe artifacts directly. `"all"` runs both backends;
    // the wasm half skips (doesn't fail) if `node` isn't on PATH — see
    // tools/conformance.sh's own comment on that distinction.
    const conformance_cmd = b.addSystemCommand(&.{ "tools/conformance.sh", "all" });
    conformance_cmd.step.dependOn(b.getInstallStep());

    // ADR-015/A1: regression test for the binary only running from inside
    // its own checkout. Needs the real `aster` on disk, not just built —
    // same reasoning as conformance_cmd above.
    const boot_elsewhere_cmd = b.addSystemCommand(&.{"tools/boot-from-elsewhere.sh"});
    boot_elsewhere_cmd.addFileArg(exe.getEmittedBin());
    boot_elsewhere_cmd.step.dependOn(b.getInstallStep());

    // tests/ui/ (spec/architecture.md's "Reload preserves state" and
    // "Windows and apps" sections): Lua modules against the fake
    // host, not a backend against the contract — needs nothing built, just
    // a system Lua 5.4.
    const ui_tests_cmd = b.addSystemCommand(&.{"tools/ui-tests.sh"});

    const test_step = b.step("test", "Run unit tests, the core line budget, the host-contract conformance suite, and the tests/ui/ suite");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&wasm_tests_cmd.step);
    test_step.dependOn(&budget_cmd.step);
    test_step.dependOn(&contract_boundary_cmd.step);
    test_step.dependOn(&renderer_ignorance_cmd.step);
    test_step.dependOn(&dangling_refs_cmd.step);
    test_step.dependOn(&conformance_cmd.step);
    test_step.dependOn(&ui_tests_cmd.step);
    test_step.dependOn(&boot_elsewhere_cmd.step);
}
