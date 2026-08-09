#!/bin/bash
#
# make-icon.sh — build HoloFrame.icns from the SVG sources in Design/.
#
# There is no SVG rasteriser on a stock macOS, but QuickLook renders SVG well, so
# `qlmanage` does the work and `sips` handles the downscaling.
#
# Two sources are used on purpose: below about 40 px the detailed icon turns to mush, so
# the 16 and 32 px slices come from the simplified variant instead. That is what the
# iconset format is for.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESIGN="$ROOT/Design"
WORK="$(mktemp -d)"
ICONSET="$WORK/HoloFrame.iconset"
trap 'rm -rf "$WORK"' EXIT

MAIN="$DESIGN/icon-b-glasses.svg"
SMALL="$DESIGN/icon-b-glasses-small.svg"
for f in "$MAIN" "$SMALL"; do
  [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

render() {  # render <svg> <out.png>
  local svg="$1" out="$2" dir
  dir="$(mktemp -d)"
  qlmanage -t -s 1024 -o "$dir" "$svg" >/dev/null 2>&1
  local produced="$dir/$(basename "$svg").png"
  [ -f "$produced" ] || { echo "qlmanage failed on $svg"; exit 1; }
  mv "$produced" "$out"
  rm -rf "$dir"
}

echo "rendering..."
render "$MAIN" "$WORK/main.png"
render "$SMALL" "$WORK/small.png"

mkdir -p "$ICONSET"
slice() {  # slice <source.png> <size> <name>
  sips -z "$2" "$2" "$1" --out "$ICONSET/$3" >/dev/null 2>&1
}

# Small sizes come from the simplified art.
slice "$WORK/small.png" 16  "icon_16x16.png"
slice "$WORK/small.png" 32  "icon_16x16@2x.png"
slice "$WORK/small.png" 32  "icon_32x32.png"
slice "$WORK/small.png" 64  "icon_32x32@2x.png"
# Everything above uses the detailed art.
slice "$WORK/main.png" 128  "icon_128x128.png"
slice "$WORK/main.png" 256  "icon_128x128@2x.png"
slice "$WORK/main.png" 256  "icon_256x256.png"
slice "$WORK/main.png" 512  "icon_256x256@2x.png"
slice "$WORK/main.png" 512  "icon_512x512.png"
cp "$WORK/main.png"          "$ICONSET/icon_512x512@2x.png"

iconutil --convert icns "$ICONSET" --output "$ROOT/Design/HoloFrame.icns"
echo "built $ROOT/Design/HoloFrame.icns"
ls -la "$ROOT/Design/HoloFrame.icns"
