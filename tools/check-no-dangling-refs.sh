#!/bin/sh
# Enforces the standing rule that this repo never points at something a reader
# who cloned it does not have: every document referenced from a tracked file
# must itself be tracked.
#
# The rule exists because it was broken. During M6 two code comments cited a
# planning document that lived one directory ABOVE the repo for the scope
# decision they depended on. Every reader outside the author's own machine got
# a dead pointer, and the decision those comments leaned on was recorded
# nowhere in the repo at all — the comment was doing an ADR's job and could
# not. It is now ADR-016.
#
# Scope: document references only. Prose about `aster-os` is fine — that is a
# public repo linked from README.md, not a file a reader is expected to find
# locally. Paths to source files are already checked by the compiler, the Lua
# loader, and build.zig's own module map.
#
# This script excludes itself from the scan, the same carve-out
# tools/check-renderer-ignorance.sh makes for its own header: a rule has to be
# able to name the thing it forbids.
set -eu

fail=0

self=tools/check-no-dangling-refs.sh

# Tracked paths and their basenames, once. The docs cite `troubleshooting.md`
# and `spec/troubleshooting.md` interchangeably and both are the same, present
# file, so a basename match counts.
known=$(git ls-files | sed 's#.*/##'; git ls-files)

refs=$(git grep -hoIE '[A-Za-z0-9_./-]+\.md' -- . ":!$self" | sed 's#^\./##' | sort -u)

for ref in $refs; do
  if ! printf '%s\n' "$known" | grep -Fxq -- "$ref" \
     && ! printf '%s\n' "$known" | grep -Fxq -- "${ref##*/}"; then
    echo "no-dangling-refs: a tracked file references '$ref', which is not in this repo" >&2
    git grep -nIF "$ref" -- . ":!$self" >&2 || true
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "no-dangling-refs: every document this repo cites is in this repo"
fi

exit "$fail"
