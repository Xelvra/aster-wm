#!/usr/bin/env node
// Runs aster-wasm-tests.wasm — the wasm backend's unit tests, built with
// tools/wasm-test-runner.zig — and reports them like any other test step.
//
// These run on the real target on purpose: src/backends/wasm/libc.zig is
// a C ABI surface (varargs, pointer width, alignment), and a native build
// of the same source would not exercise the ABI the Lua C sources
// actually call it through.
//
// The imports below are stubs, not a working host: nothing here drives a
// frame or touches storage — that is tools/wasm-conformance.js's job.
// They exist because the module declares them (src/host/fs_wasm.zig,
// src/backends/wasm/backend.zig), and WebAssembly.instantiate refuses a
// module whose imports aren't all supplied.

"use strict";
const fs = require("fs");

const wasmPath = process.argv[2] || "zig-out/bin/aster-wasm-tests.wasm";
if (!fs.existsSync(wasmPath)) {
  console.error(`wasm-tests: ${wasmPath} not built — run 'zig build' first`);
  process.exit(1);
}

const unreachableImport = (name) => () => {
  throw new Error(`wasm-tests: a test called the host import ${name}`);
};

const imports = {
  aster: {
    js_log: () => {},
    js_present: () => {},
    js_now_ms: () => 0,
    js_wall_clock_ms: () => 0,
    js_utc_offset_min: () => 0,
    js_fs_read: unreachableImport("js_fs_read"),
    js_fs_write: unreachableImport("js_fs_write"),
    js_fs_list_count: unreachableImport("js_fs_list_count"),
    js_fs_list_entry: unreachableImport("js_fs_list_entry"),
    js_fs_remove: unreachableImport("js_fs_remove"),
    js_fs_rename: unreachableImport("js_fs_rename"),
  },
};

WebAssembly.instantiate(fs.readFileSync(wasmPath), imports)
  .then(({ instance }) => {
    const total = instance.exports.aster_test_count();
    const failed = instance.exports.aster_run_tests();
    if (failed > 0) {
      const ptr = instance.exports.aster_failed_names_ptr();
      const len = instance.exports.aster_failed_names_len();
      const names = Buffer.from(instance.exports.memory.buffer, ptr, len).toString("utf8");
      for (const name of names.split("\n").filter(Boolean)) console.error(`${name}: FAIL`);
    }
    console.log("---");
    console.log(`wasm-tests: ${total - failed} passed, ${failed} failed`);
    process.exit(failed === 0 ? 0 : 1);
  })
  .catch((e) => {
    console.error("wasm-tests: fatal:", e.stack || e.message);
    process.exit(1);
  });
