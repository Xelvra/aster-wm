#!/bin/sh
# Enforces the claim in README: the core is small enough to read in an afternoon.
# Wired into `zig build test`, so going over the budget fails the build.
set -eu

BUDGET=1600
ACTUAL=$(cat lua/aster/*.lua | grep -vc '^[[:space:]]*\(--.*\)\?$')

printf 'core: %s / %s lines\n' "$ACTUAL" "$BUDGET"

if [ "$ACTUAL" -gt "$BUDGET" ]; then
  cat >&2 <<'MSG'

core is over budget.

This is not bureaucracy: "you can read the whole window manager in an afternoon"
is the product, and this limit is the only thing that keeps that true.

If the code you added runs inside a window, it belongs in apps/, not lua/aster/.
If you believe the budget itself is wrong, open an issue and make the case.
MSG
  exit 1
fi
