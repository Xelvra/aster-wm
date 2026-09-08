#!/bin/sh
# Runs spec/conformance/ against a backend. Exit codes per script: 0 pass,
# 1 fail, 2 declared skip (backend genuinely can't run it — never counted
# as a pass). `$1` selects the backend, default `sdl`.
set -u

backend="${1:-sdl}"

run_sdl() {
  BIN=./zig-out/bin/aster-conformance
  if [ ! -x "$BIN" ]; then
    echo "conformance: $BIN not built — run 'zig build' first" >&2
    return 1
  fi

  pass=0
  fail=0
  skip=0

  for script in spec/conformance/*.lua; do
    out=$(SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" "$BIN" "$script" 2>&1)
    code=$?
    case "$code" in
      0) pass=$((pass + 1)); echo "$out" ;;
      2) skip=$((skip + 1)); echo "$out" ;;
      *) fail=$((fail + 1)); printf '%s: FAIL\n%s\n' "$script" "$out" ;;
    esac
  done

  echo "---"
  echo "conformance (sdl): $pass passed, $skip skipped (manual), $fail failed"
  [ "$fail" -eq 0 ]
}

run_wasm() {
  if ! command -v node >/dev/null 2>&1; then
    # Not a backend gap (unlike a real caps.inject=false skip) — this
    # machine's toolchain gap, loud rather than a silent pass. See
    # CONTRIBUTING.md: `zig build && zig build test` is the whole bar,
    # and this is the one part of it that reaches outside Zig's own
    # toolchain (ADR-013's wasm backend runs under a JS host by
    # definition — there is no way to execute a .wasm without one).
    echo "conformance (wasm): SKIPPED — node not found in PATH" >&2
    return 0
  fi
  WASM=./zig-out/bin/aster-wasm-conformance.wasm
  if [ ! -f "$WASM" ]; then
    echo "conformance: $WASM not built — run 'zig build' first" >&2
    return 1
  fi
  node tools/wasm-conformance.js "$WASM"
}

case "$backend" in
  sdl) run_sdl ;;
  wasm) run_wasm ;;
  all)
    run_sdl
    sdl_status=$?
    run_wasm
    wasm_status=$?
    [ "$sdl_status" -eq 0 ] && [ "$wasm_status" -eq 0 ]
    ;;
  *)
    echo "conformance.sh: unknown backend '$backend' (drm, baremetal not implemented yet)" >&2
    exit 1
    ;;
esac
