#!/bin/sh
# Enforces spec/architecture.md's "Four rules" 1 and 2 with a mechanism, not
# a promise: lua/aster/ may only call host.<one of the contract's twelve
# functions>, and must never require() a specific app by name (ADR-007 —
# the core doesn't know any app's name, including the ones shipped here).
set -eu

fail=0

ALLOWED="info surface present wait now_ms clock read write list remove rename log"

names=$(grep -rhoE 'host\.[A-Za-z_][A-Za-z0-9_]*' lua/aster/*.lua | sed 's/host\.//' | sort -u)
for name in $names; do
  found=0
  for a in $ALLOWED; do
    [ "$name" = "$a" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "contract-boundary: lua/aster/ calls host.$name, which is not one of the twelve host-contract functions" >&2
    fail=1
  fi
done

if grep -nE "require\([\"']apps\." lua/aster/*.lua; then
  echo "contract-boundary: lua/aster/ must never require() a specific app by name (ADR-007)" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "contract-boundary: lua/aster/ calls only host.* and stays app-agnostic"
fi

exit "$fail"
