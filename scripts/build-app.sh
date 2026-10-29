#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "$configuration" in
  debug|release) ;;
  *) printf 'Configuration must be debug or release.\n' >&2; exit 2 ;;
esac

if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == *CommandLineTools* ]]; then
  printf 'Building the app requires Xcode; select it with xcode-select or DEVELOPER_DIR.\n' >&2
  exit 1
fi

architectures=("$(uname -m)")
if [[ "$configuration" == release ]]; then architectures=(arm64 x86_64); fi
scratch="$root/.build/packaging-build"
build_args=(--scratch-path "$scratch" --build-system xcode -c "$configuration")
verify_args=()
for architecture in "${architectures[@]}"; do
  build_args+=(--arch "$architecture")
  verify_args+=(--arch "$architecture")
done
# SwiftPM's Xcode build system merges every slice before bundle assembly/signing.
swift build "${build_args[@]}" >&2
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
framework="$scratch/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
app="$root/.build/Herdling.app"

work="$(mktemp -d "$root/.build/herdling-app-XXXXXX")"
cleanup() {
  local rc=$?
  if [[ -d "$work/previous.app" && ! -e "$app" ]]; then
    if ! mv "$work/previous.app" "$app"; then
      printf 'Could not restore previous app; preserved at %s/previous.app\n' "$work" >&2
      exit 1
    fi
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staged_app="$work/Herdling.app"
mkdir -p "$staged_app/Contents/"{MacOS,Resources,Frameworks}
cp "$bin_dir/Herdling" "$staged_app/Contents/MacOS/Herdling"
cp "$root/Resources/Info.plist" "$staged_app/Contents/Info.plist"
cp \
  "$root/Resources/herdr-mark.svg" \
  "$root/Resources/THIRD_PARTY_NOTICES.md" \
  "$root/Resources/Herdr-LICENSE.txt" \
  "$root/Resources/Sparkle-LICENSE.txt" \
  "$staged_app/Contents/Resources/"
# Keep the official framework, helper signatures, symlinks and permissions intact.
ditto "$framework" "$staged_app/Contents/Frameworks/Sparkle.framework" >&2
codesign --force --sign - "$staged_app" >&2
bash "$root/scripts/verify-app-packaging.sh" --app "$staged_app" "${verify_args[@]}" >&2

# shortcut: SIGKILL can interrupt the two renames; use atomic exchange if crash-safe publication is required.
if [[ -e "$app" ]]; then mv "$app" "$work/previous.app"; fi
mv "$staged_app" "$app"

printf '%s\n' "$app"
