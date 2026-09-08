#!/usr/bin/env node
// Runs spec/conformance/ against aster-wasm-conformance.wasm under Node —
// the wasm-target equivalent of tools/conformance.sh's SDL run. Exit
// codes per script match src/main_wasm.zig's aster_run_conformance: 0
// pass, 1 fail, 2 declared skip.
//
// The "aster" imports are src/backends/wasm/glue.js's own `hostImports`,
// the same code the browser runs — this file only swaps localStorage for
// an in-memory store, since Node has no localStorage. A second
// implementation of those eleven functions is what B25 had to fix twice
// and what let B28 through, so there isn't one any more.

"use strict";
const fs = require("fs");
const path = require("path");
const glue = require(path.join(__dirname, "..", "src", "backends", "wasm", "glue.js"));

const wasmPath = process.argv[2] || "zig-out/bin/aster-wasm-conformance.wasm";
if (!fs.existsSync(wasmPath)) {
  console.error(`wasm-conformance: ${wasmPath} not built — run 'zig build' first`);
  process.exit(1);
}

// Node has no localStorage, so it gets one: a Map of strings, which is
// what the Web Storage API is (values are coerced to strings and stored
// as UTF-16 code units). Standing this up instead of handing glue.js a
// byte-keyed store of our own is deliberate — the encoding a store does
// on the way in and out is exactly where B28 lived, so the suite has to
// run the browser's store, not a friendlier one.
function installLocalStorage() {
  const entries = new Map();
  globalThis.localStorage = {
    getItem: (k) => (entries.has(k) ? entries.get(k) : null),
    setItem: (k, v) => entries.set(String(k), String(v)),
    removeItem: (k) => entries.delete(k),
    key: (i) => [...entries.keys()][i] ?? null,
    get length() {
      return entries.size;
    },
  };
}
installLocalStorage();

let instance;
const imports = {
  aster: glue.hostImports({
    memory: () => instance.exports.memory.buffer,
    store: glue.localStorageStore(),
    present: () => {},
    log: (line) => console.log(line),
  }),
};

const scriptNames = fs
  .readdirSync("spec/conformance")
  .filter((f) => f.endsWith(".lua"))
  .map((f) => f.replace(/\.lua$/, ""))
  .sort();

WebAssembly.instantiate(fs.readFileSync(wasmPath), imports)
  .then(({ instance: inst }) => {
    instance = inst;
    instance.exports.aster_init(1024, 768);

    let pass = 0, fail = 0, skip = 0;
    for (const name of scriptNames) {
      const nameBytes = Buffer.from(name, "utf8");
      const ptr = instance.exports.malloc(nameBytes.length);
      Buffer.from(instance.exports.memory.buffer).set(nameBytes, ptr);
      const code = instance.exports.aster_run_conformance(ptr, nameBytes.length);
      instance.exports.free(ptr);
      if (code === 0) pass++;
      else if (code === 2) skip++;
      else {
        fail++;
        console.error(`${name}: FAIL (code ${code})`);
      }
    }

    console.log("---");
    console.log(`wasm-conformance: ${pass} passed, ${skip} skipped (manual), ${fail} failed`);
    process.exit(fail === 0 ? 0 : 1);
  })
  .catch((e) => {
    console.error("wasm-conformance: fatal:", e.stack || e.message);
    process.exit(1);
  });
