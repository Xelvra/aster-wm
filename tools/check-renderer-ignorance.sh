#!/bin/sh
# Enforces spec/architecture.md's "Four rules" 3 ("policy up, mechanism
# down") with a mechanism, not a promise: src/render/ draws rectangles and
# glyphs onto a Surface and must never know what a window, a title, or a
# workspace is. Comments are allowed to say the rule out loud (this file's
# own header comments do); only identifiers in actual code may not.
set -eu

fail=0

for f in src/render/*.zig; do
  # Strip //, ///, and //! line comments before scanning: this repo's own
  # rule-3 comments (e.g. "it never knows what a window is") would
  # otherwise trip the check they're describing.
  hits=$(sed -E 's#//.*$##' "$f" | grep -inE '\b(window|title|workspace)[A-Za-z0-9_]*\b' || true)
  if [ -n "$hits" ]; then
    echo "renderer-ignorance: $f references window/title/workspace outside a comment:" >&2
    echo "$hits" >&2
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "renderer-ignorance: src/render/ knows nothing about windows, titles, or workspaces"
fi

exit "$fail"
