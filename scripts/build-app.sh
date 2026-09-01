#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$configuration" >&2
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app="$root/.build/Herdling.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp "$bin_dir/Herdling" "$app/Contents/MacOS/Herdling"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp \
  "$root/Resources/herdr-mark.svg" \
  "$root/Resources/THIRD_PARTY_NOTICES.md" \
  "$root/Resources/Herdr-LICENSE.txt" \
  "$app/Contents/Resources/"
codesign --force --sign - "$app" >/dev/null

printf '%s\n' "$app"
