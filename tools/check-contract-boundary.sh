#!/bin/sh
# Enforces spec/architecture.md's "Four rules" 1 and 2 with a mechanism, not
# a promise: lua/aster/ may only call host.<one of the contract's twelve
# functions>, may only reach for the two infrastructure globals rule 1 names,
# and must never require() a specific app or bar widget by name
# (ADR-007 — the core doesn't know the name of any app or widget, including
# the ones shipped here; widgets/ is apps/'s counterpart for the bar's
# draw(bar, surface, x, y, h) -> width contract, same discipline applies).
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

# Rule 1 says the core calls nothing outside host.* and require("aster.*").
# Two globals are the documented exception, and both exist because they are
# infrastructure the host installs rather than contract surface:
#
#   __native_render      the shared drawing library (lua/aster/render.lua),
#                        registered by src/host/bindings.zig — deliberately
#                        NOT a host.* function, since it is always present
#                        regardless of backend.
#   __aster_default_config  ADR-015's config seed, pushed once by
#                        src/host/modules.zig's pushDefaultConfig and read
#                        only by lua/aster/loop.lua's boot().
#
# A third one would quietly widen the boundary rule 1 draws, one commit at a
# time, exactly the way P2 says the contract itself must not grow. Adding one
# has to be a deliberate edit here, not something that lands green.
ALLOWED_GLOBALS="__native_render __aster_default_config"

# Lua's own metatable keys are spelled with the same leading underscores but
# are table fields, not globals. The full 5.4 set is listed so that reaching
# for a __close or a __tostring later doesn't read as a new global and send
# someone editing ALLOWED_GLOBALS for the wrong reason.
METAMETHODS="__index __newindex __call __tostring __len __eq __lt __le
  __concat __add __sub __mul __div __mod __pow __unm __idiv __band __bor
  __bxor __bnot __shl __shr __close __gc __mode __name __metatable __pairs"

# Line comments are stripped first, the same way tools/check-renderer-ignorance.sh
# strips its own and for the same reason: the core's comments name these
# globals while explaining them, and should keep being able to name one this
# list does not allow (e.g. describing what the core deliberately does NOT
# reach for). Only real code is the boundary. lua/aster/ has no --[[ ]] block
# comments and no string literal containing "--", so a line-wise strip is
# exact here rather than approximate.
globals=$(sed -E 's/--.*$//' lua/aster/*.lua | grep -oE '__[A-Za-z0-9_]+' | sort -u)
for name in $globals; do
  found=0
  for a in $ALLOWED_GLOBALS $METAMETHODS; do
    [ "$name" = "$a" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "contract-boundary: lua/aster/ references the global $name; rule 1 allows only $ALLOWED_GLOBALS besides host.*" >&2
    fail=1
  fi
done

if grep -nE "require\([\"'](apps|widgets)\." lua/aster/*.lua; then
  echo "contract-boundary: lua/aster/ must never require() a specific app or bar widget by name (ADR-007)" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "contract-boundary: lua/aster/ calls only host.* and stays app-agnostic"
fi

exit "$fail"
