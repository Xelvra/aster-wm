#!/bin/sh
# ADR-015: `aster` must boot from any working directory, with no
# ~/.config/aster/wm.lua yet, without needing anything from a checkout of
# this repo — a downloaded release binary has none. Regression test for
# the bug ADR-012 recorded and ADR-015 closes:
#
#   $ cd /tmp/elsewhere && SDL_VIDEODRIVER=dummy aster
#   lua error: module 'aster' not found:
#       no file 'lua/aster/init.lua'
#       ...
#
# Runs the real `aster` binary (not aster-conformance, which bypasses
# aster.boot() entirely) from a scratch directory with a scratch $HOME,
# under a short timeout — SDL_VIDEODRIVER=dummy never delivers a real quit
# event, so a clean run is expected to be killed BY the timeout, not to
# exit on its own. Exit code 124 (GNU coreutils' timeout) or the 143
# (128+SIGTERM) some `timeout` implementations use are both "ran fine
# until we killed it"; anything else (a Lua/Zig error prints an "error:"
# or "panic" line to stderr and set -e will still let the here-documented
# checks below run against $OUT) is a real failure.
set -u

ASTER=${1:-zig-out/bin/aster}
if [ ! -x "$ASTER" ]; then
  echo "boot-from-elsewhere: $ASTER not built — run 'zig build' first" >&2
  exit 1
fi
# build.zig passes a cache-relative path; resolve it before cd'ing below,
# since the whole point of this test is running from a different cwd.
ASTER=$(cd "$(dirname "$ASTER")" && pwd)/$(basename "$ASTER")

WORKDIR=$(mktemp -d)
FAKEHOME=$(mktemp -d)
trap 'rm -rf "$WORKDIR" "$FAKEHOME"' EXIT

OUT=$(cd "$WORKDIR" && HOME="$FAKEHOME" SDL_VIDEODRIVER=dummy timeout -s TERM 2 "$ASTER" 2>&1)
code=$?

fail=0

case "$code" in
  124 | 143) : ;; # killed by the timeout after a clean boot — expected
  *)
    fail=1
    printf 'boot-from-elsewhere: FAIL — unexpected exit code %s\n%s\n' "$code" "$OUT" >&2
    ;;
esac

if echo "$OUT" | grep -qiE 'panic|lua error|module .* not found'; then
  fail=1
  printf 'boot-from-elsewhere: FAIL — crash output on stderr\n%s\n' "$OUT" >&2
fi

CONFIG="$FAKEHOME/.config/aster/wm.lua"
if [ ! -f "$CONFIG" ]; then
  fail=1
  echo "boot-from-elsewhere: FAIL — $CONFIG was never seeded" >&2
elif ! grep -q 'aster.wm.adopt' "$CONFIG"; then
  fail=1
  echo "boot-from-elsewhere: FAIL — seeded config doesn't look like config/wm.lua" >&2
fi

if [ "$fail" -eq 0 ]; then
  echo "boot-from-elsewhere: PASS — booted from $WORKDIR with HOME=$FAKEHOME, seeded $CONFIG"
fi

exit "$fail"
