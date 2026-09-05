#!/bin/sh
# Runs spec/conformance/ against aster-conformance (the only build with
# host._inject — see build.zig and spec/host-contract.md §9.4). Exit codes
# per script: 0 pass, 1 fail, 2 declared skip (backend genuinely can't run
# it — never counted as a pass).
set -u

BIN=./zig-out/bin/aster-conformance
if [ ! -x "$BIN" ]; then
  echo "conformance: $BIN not built — run 'zig build' first" >&2
  exit 1
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
echo "conformance: $pass passed, $skip skipped (manual), $fail failed"

[ "$fail" -eq 0 ]
