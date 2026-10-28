#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Command Line Tools ship no SwiftUIMacros plugin, so SDK 27+ cannot compile SwiftUI.
# Falling back to the newest 26.x SDK keeps CLT-only builds working; selecting Xcode lifts this.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  clt_sdk="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | tail -1)"
  [[ -n "$clt_sdk" ]] && export SDKROOT="$clt_sdk"
fi

# Swift Build's resource accessors search Contents/Resources instead of the build machine's path.
swift build --build-system swiftbuild -c "$configuration" >&2
bin_dir="$(swift build --build-system swiftbuild -c "$configuration" --show-bin-path)"
app="$root/.build/Herdling.app"
shortcut_resources="$bin_dir/KeyboardShortcuts_KeyboardShortcuts.bundle"

if [[ ! -d "$shortcut_resources" ]]; then
  printf 'Missing KeyboardShortcuts resources: %s\n' "$shortcut_resources" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp "$bin_dir/Herdling" "$app/Contents/MacOS/Herdling"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp \
  "$root/Resources/herdr-mark.svg" \
  "$root/Resources/THIRD_PARTY_NOTICES.md" \
  "$root/Resources/Herdr-LICENSE.txt" \
  "$root/Resources/KeyboardShortcuts-LICENSE.txt" \
  "$app/Contents/Resources/"
cp -R "$shortcut_resources" "$app/Contents/Resources/"
codesign --force --sign - "$app" >/dev/null

printf '%s\n' "$app"
