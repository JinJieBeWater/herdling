#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: bash scripts/verify-app-packaging.sh --app APP\n'
}

app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --app)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app="$2"
      shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! -f "$app/Contents/MacOS/Herdling" || ! -f "$app/Contents/Info.plist" ]]; then
  printf 'Missing app executable or Info.plist: %s\n' "${app:-<unset>}" >&2
  usage >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
codesign --verify --deep --strict "$app"
for resource in herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt; do
  cmp "$root/Resources/$resource" "$app/Contents/Resources/$resource"
done
printf 'packaging_verified=%s\n' "$app"
