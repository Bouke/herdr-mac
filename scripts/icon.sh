#!/usr/bin/env bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns (needs rsvg-convert: brew install librsvg).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SET=$(mktemp -d -t AppIcon.XXXXXX)/AppIcon.iconset
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$ROOT/Resources/AppIcon.svg" -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ROOT/Resources/AppIcon.svg" -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "$ROOT/Resources/AppIcon.icns"
