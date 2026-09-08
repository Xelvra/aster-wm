#!/bin/sh
# Runs the wasm backend's unit tests (tools/wasm-tests.js) over the test
# binary build.zig hands us as $1.
#
# The node guard matches tools/conformance.sh's: this is the same
# toolchain gap, not a backend gap — a .wasm cannot be executed without a
# JS host, so a machine without node skips loudly instead of failing.
set -eu

WASM=${1:-zig-out/bin/aster-wasm-tests.wasm}

if ! command -v node >/dev/null 2>&1; then
  echo "wasm-tests: SKIPPED — node not found in PATH" >&2
  exit 0
fi

exec node tools/wasm-tests.js "$WASM"
