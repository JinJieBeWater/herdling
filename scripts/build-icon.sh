#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg; requires rsvg-convert (brew install librsvg).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
iconset="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$iconset")"' EXIT
mkdir "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" "$root/Resources/AppIcon.svg" -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" "$root/Resources/AppIcon.svg" -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$root/Resources/AppIcon.icns"
