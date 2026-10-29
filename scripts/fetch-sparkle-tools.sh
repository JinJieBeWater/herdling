#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
resolved="$(python3 -c 'import json,sys; print(next(p["state"]["version"] for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"))' "$root/Package.resolved")"
if [[ "$resolved" != "$version" ]]; then
  printf 'Update the pinned Sparkle tools version and checksum to match Package.resolved.\n' >&2
  exit 1
fi

directory="$root/.build/sparkle-tools-$version"
mkdir -p "$directory"
archive="$directory/Sparkle-$version.tar.xz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
    --output "$archive.download" >&2
  mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c - >&2
tar -xJf "$archive" -C "$directory" ./bin ./LICENSE
printf '%s\n' "$directory/bin"
