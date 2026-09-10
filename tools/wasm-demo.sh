#!/bin/sh
# tools/wasm-demo.sh — builds the wasm backend, drops the artifacts into
# docs/demo/ (same two files ci.yml's pages.yml job produces, gitignored
# there so a local build never gets committed by accident — see
# .gitignore's "WebAssembly demo output" entry), and serves docs/demo/
# over plain HTTP so a browser can actually load it (opening index.html
# via file:// blocks on CORS for the .wasm fetch).
#
# Usage: tools/wasm-demo.sh [port]   (default 8934)
set -eu

PORT="${1:-8934}"

# Runnable from anywhere, not just the repo root, and however it's
# invoked (a relative path, or a symlink to it — plain `dirname "$0"`
# gets the symlink's own directory, not the real script's, so this uses
# python3 to resolve it properly; python3 is already a hard dependency
# below, for the HTTP server).
REPO_ROOT="$(python3 -c 'import os, sys; print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))' "$0")"
cd "$REPO_ROOT"

zig build wasm -Doptimize=ReleaseSmall

cp src/backends/wasm/glue.js docs/demo/glue.js
cp zig-out/bin/aster-wasm.wasm docs/demo/aster-wasm.wasm

URL="http://localhost:${PORT}/index.html"
echo "wasm-demo: serving docs/demo/ at ${URL} (Ctrl+C to stop)"

# Best-effort: open a browser automatically where a launcher exists: a
# missing one (a bare server, CI) is not an error, just no auto-open.
(
  sleep 0.5
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1
  elif command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1
  fi
) &

cd docs/demo
exec python3 -m http.server "$PORT"
