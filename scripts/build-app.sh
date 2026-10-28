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

architecture="$(uname -m)"
swift build --build-system xcode --arch "$architecture" -c "$configuration" >&2
bin_dir="$(swift build --build-system xcode --arch "$architecture" -c "$configuration" --show-bin-path)"
app="$root/.build/Herdling.app"
shortcut_resources="$bin_dir/KeyboardShortcuts_KeyboardShortcuts.bundle"

if [[ ! -d "$shortcut_resources" ]]; then
  printf 'Missing KeyboardShortcuts resources: %s\n' "$shortcut_resources" >&2
  exit 1
fi

work="$(mktemp -d "$root/.build/herdling-app-XXXXXX")"
trap 'rm -rf "$work"' EXIT
staged_app="$work/Herdling.app"
mkdir -p "$staged_app/Contents/MacOS"
mkdir -p "$staged_app/Contents/Resources"
cp "$bin_dir/Herdling" "$staged_app/Contents/MacOS/Herdling"
cp "$root/Resources/Info.plist" "$staged_app/Contents/Info.plist"
cp \
  "$root/Resources/herdr-mark.svg" \
  "$root/Resources/THIRD_PARTY_NOTICES.md" \
  "$root/Resources/Herdr-LICENSE.txt" \
  "$root/Resources/KeyboardShortcuts-LICENSE.txt" \
  "$staged_app/Contents/Resources/"
cp -R "$shortcut_resources" "$staged_app/Contents/Resources/"
codesign --force --sign - "$staged_app" >/dev/null

# shortcut: final replacement is not atomic; add rollback if interrupted publication must preserve the old app.
rm -rf "$app"
mv "$staged_app" "$app"

printf '%s\n' "$app"
