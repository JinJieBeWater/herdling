#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/verify-app-packaging.sh --app APP --accessor RESOURCE_ACCESSOR

Verify a signed app and run SwiftPM's generated resource lookup in a relocated copy.
Herdling itself is not launched; no user preferences or shortcuts are changed.

Examples:
  bash scripts/verify-app-packaging.sh --app .build/Herdling.app \
    --accessor .build/out/Intermediates.noindex/KeyboardShortcuts.build/Debug/KeyboardShortcuts-t.build/DerivedSources/resource_bundle_accessor.swift
EOF
}

app=""
accessor=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help) usage; exit 0 ;;
    --app|--accessor)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      if [[ "$1" == --app ]]; then app="$2"; else accessor="$2"; fi
      shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ ! -d "$app/Contents/MacOS" ]]; then
  printf 'Missing app Contents/MacOS directory: %s\n' "${app:-<unset>}" >&2
  usage >&2
  exit 2
fi
if [[ ! -f "$accessor" ]]; then
  printf 'Missing generated resource accessor: %s\n' "${accessor:-<unset>}" >&2
  usage >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/herdling-packaging-check-XXXXXX)"
trap 'rm -rf "$work"' EXIT
codesign --verify --deep --strict "$app"
cp -R "$app" "$work/Herdling.app"

cat > "$work/main.swift" <<'SWIFT'
import Foundation
import Darwin

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("Packaging failure: \(message)\n", stderr)
        exit(1)
    }
}

let resources = Bundle.main.resourceURL!.standardizedFileURL
let module = Bundle.module
let expected = resources.appendingPathComponent("KeyboardShortcuts_KeyboardShortcuts.bundle")
require(module.bundleURL.standardizedFileURL == expected, "resource lookup escaped app: \(module.bundleURL.path)")

for (language, expectedText) in [("en", "Record Shortcut"), ("zh-Hans", "设置快捷键")] {
    guard let path = module.path(forResource: language, ofType: "lproj"),
          let localization = Bundle(path: path) else {
        require(false, "missing \(language) localization")
        continue
    }
    let text = localization.localizedString(forKey: "record_shortcut", value: nil, table: nil)
    require(text == expectedText, "incorrect \(language) recorder text: \(text)")
}

for language in module.localizations {
    guard let path = module.path(forResource: language, ofType: "lproj"),
          let localization = Bundle(path: path) else {
        require(false, "missing \(language) localization")
        continue
    }
    let text = localization.localizedString(forKey: "record_shortcut", value: nil, table: nil)
    require(!text.isEmpty && text != "record_shortcut", "unresolved \(language) recorder text")
}
print("resource_bundle=\(module.bundleURL.path)")
print("localizations=\(module.localizations.sorted().joined(separator: ","))")
SWIFT

swiftc -DDEBUG "$accessor" "$work/main.swift" -o "$work/Herdling.app/Contents/MacOS/Herdling"
env -u PACKAGE_RESOURCE_BUNDLE_PATH -u PACKAGE_RESOURCE_BUNDLE_URL \
  "$work/Herdling.app/Contents/MacOS/Herdling"

for resource in herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt KeyboardShortcuts-LICENSE.txt; do
  cmp "$root/Resources/$resource" "$app/Contents/Resources/$resource"
done
printf 'packaging_verified=%s\n' "$app"
