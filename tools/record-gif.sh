#!/bin/sh
# tools/record-gif.sh — records the running desktop into docs/media/<name>.gif.
# Usage: tools/record-gif.sh <name> [seconds]
#
# Capture: wf-recorder under Wayland, ffmpeg's x11grab under X11 — whichever
# display is actually running. Convert: ffmpeg's own palettegen/paletteuse
# two-pass, not gifski (not every contributor's machine has that installed;
# ffmpeg is already a build/CI dependency of nothing here, but common enough
# to assume, and the two-pass palette approach gets close to gifski's output
# quality without a third-party binary).
#
# Not run by CI — this is a workflow for a human at a real desktop, recording
# `aster` (the SDL backend) doing something. Point it at the window, run this,
# do the thing on screen for `seconds`, done.
set -eu

name="${1:?usage: record-gif.sh <name> [seconds]}"
seconds="${2:-8}"
out_dir="docs/media"
mkdir -p "$out_dir"

raw="$(mktemp --suffix=.mp4)"
palette="$(mktemp --suffix=.png)"
trap 'rm -f "$raw" "$palette"' EXIT

if command -v wf-recorder >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
  echo "record-gif: recording ${seconds}s via wf-recorder — do the thing now" >&2
  timeout "$seconds" wf-recorder -f "$raw" || true
elif [ -n "${DISPLAY:-}" ]; then
  echo "record-gif: recording ${seconds}s via ffmpeg x11grab — do the thing now" >&2
  ffmpeg -y -f x11grab -video_size 1024x768 -i "$DISPLAY" -t "$seconds" "$raw"
else
  echo "record-gif: no Wayland (\$WAYLAND_DISPLAY) or X11 (\$DISPLAY) session found" >&2
  exit 1
fi

# 800px wide, 15fps: small enough to clear the 3MB budget for a several-
# second clip without gifski's extra dependency; adjust scale/fps by hand
# here first if a specific recording still comes in over budget.
ffmpeg -y -i "$raw" -vf "fps=15,scale=800:-1:flags=lanczos,palettegen" "$palette"
ffmpeg -y -i "$raw" -i "$palette" \
  -filter_complex "fps=15,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse" \
  "$out_dir/$name.gif"

size=$(stat -c%s "$out_dir/$name.gif" 2>/dev/null || stat -f%z "$out_dir/$name.gif")
echo "record-gif: wrote $out_dir/$name.gif ($((size / 1024)) KiB)"
if [ "$size" -gt $((3 * 1024 * 1024)) ]; then
  echo "record-gif: WARNING — over the 3MB budget, lower fps/scale in this script or trim seconds" >&2
fi
