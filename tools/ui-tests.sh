#!/bin/sh
# Runs tests/ui/*.lua against tests/ui/fakehost.lua under a plain host Lua
# 5.4 interpreter — no graphics, no real backend. This is the other half of
# spec/architecture.md's "Backends" section: spec/conformance/ tests a
# BACKEND against the contract; tests/ui/ tests the Lua modules themselves
# (windows, apps, reload) against a fake host, so it runs in a fraction of
# a second and needs nothing built.
set -u

LUA=${LUA:-lua5.4}
if ! command -v "$LUA" >/dev/null 2>&1; then
  echo "tests/ui: $LUA not found" >&2
  exit 1
fi

pass=0
fail=0

for script in tests/ui/*.lua; do
  case "$script" in
    tests/ui/fakehost.lua) continue ;;
  esac
  out=$("$LUA" "$script" 2>&1)
  code=$?
  if [ "$code" -eq 0 ]; then
    pass=$((pass + 1)); echo "$out"
  else
    fail=$((fail + 1)); printf '%s: FAIL\n%s\n' "$script" "$out"
  fi
done

echo "---"
echo "tests/ui: $pass passed, $fail failed"

[ "$fail" -eq 0 ]
