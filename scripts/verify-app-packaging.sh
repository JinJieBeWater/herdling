#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: bash scripts/verify-app-packaging.sh --app APP [--arch ARCH ...]\n'
}

app=""
architectures=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --app)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app="$2"
      shift 2 ;;
    --arch)
      [[ $# -ge 2 && ( "$2" == arm64 || "$2" == x86_64 ) ]] || { usage >&2; exit 2; }
      architectures+=("$2")
      shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! -f "$app/Contents/MacOS/Herdling" || ! -f "$app/Contents/Info.plist" ]]; then
  printf 'Missing app executable or Info.plist: %s\n' "${app:-<unset>}" >&2
  usage >&2
  exit 2
fi
if [[ ${#architectures[@]} == 0 ]]; then architectures=(arm64 x86_64); fi

root="$(cd "$(dirname "$0")/.." && pwd)"
framework="$app/Contents/Frameworks/Sparkle.framework"
version="$framework/Versions/Current"
for link in Versions/Current Sparkle Resources Autoupdate Updater.app XPCServices; do
  [[ -L "$framework/$link" ]] || { printf 'Missing framework symlink: %s\n' "$link" >&2; exit 1; }
done
while IFS= read -r -d '' link; do
  [[ "$(readlink "$link")" != /* && -e "$link" ]] || {
    printf 'Broken or absolute framework symlink: %s\n' "$link" >&2; exit 1;
  }
done < <(find "$framework" -type l -print0)

binaries=(
  "$app/Contents/MacOS/Herdling"
  "$version/Sparkle"
  "$version/Autoupdate"
  "$version/Updater.app/Contents/MacOS/Updater"
  "$version/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  "$version/XPCServices/Installer.xpc/Contents/MacOS/Installer"
)
for binary in "${binaries[@]}"; do
  [[ -x "$binary" ]] || { printf 'Missing executable: %s\n' "$binary" >&2; exit 1; }
  for architecture in "${architectures[@]}"; do
    lipo "$binary" -verify_arch "$architecture"
  done
  loads="$(otool -l "$binary")"
  dependencies="$(otool -L "$binary")"
  # Only system absolute paths and bundle-relative paths can survive relocation.
  paths="$(printf '%s\n' "$loads" | awk '/cmd LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset.*$/, ""); print }')"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
      @executable_path/*|@loader_path/*|/usr/lib/swift) ;;
      *) printf 'Non-relocatable Runpath in %s: %s\n' "$binary" "$path" >&2; exit 1 ;;
    esac
  done <<< "$paths"
  while IFS= read -r dependency; do
    case "$dependency" in
      @rpath/*|@executable_path/*|@loader_path/*|/usr/lib/*|/System/Library/*) ;;
      *) printf 'Non-relocatable dependency in %s: %s\n' "$binary" "$dependency" >&2; exit 1 ;;
    esac
  done < <(printf '%s\n' "$dependencies" | awk '/compatibility version/ { sub(/^[ \t]*/, ""); sub(/ \(compatibility version.*$/, ""); print }')
  codesign --verify --strict "$binary"
done
main_loads="$(otool -l "$app/Contents/MacOS/Herdling")"
main_dependencies="$(otool -L "$app/Contents/MacOS/Herdling")"
grep -q 'path @executable_path/../Frameworks ' <<< "$main_loads"
grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle ' <<< "$main_dependencies"
codesign --verify --deep --strict "$app"
for resource in herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt Sparkle-LICENSE.txt; do
  cmp "$root/Resources/$resource" "$app/Contents/Resources/$resource"
done
printf 'packaging_verified=%s\n' "$app"
