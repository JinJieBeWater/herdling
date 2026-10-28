#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# shortcut: Swift 6.2 needs Xcode's app resource layout; use swiftbuild when CI moves to Swift 6.4.
if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == *CommandLineTools* ]]; then
  printf 'Building the app requires Xcode; select it with xcode-select or DEVELOPER_DIR.\n' >&2
  exit 1
fi

swift build --build-system xcode -c "$configuration" >&2
bin_dir="$(swift build --build-system xcode -c "$configuration" --show-bin-path)"
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
