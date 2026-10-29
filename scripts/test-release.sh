#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$(cd "${1:?Usage: bash scripts/test-release.sh SPARKLE_BIN}" && pwd)"
work="$(mktemp -d "$root/.build/herdling-release-test-XXXXXX")"
trap 'rm -rf "$work"' EXIT
umask 077
mkdir -p "$work/scripts" "$work/.build"
cp "$root/scripts/prepare-release.sh" "$root/scripts/verify-app-packaging.sh" "$work/scripts/"
cp -R "$root/Resources" "$work/Resources"
ditto "$root/.build/Herdling.app" "$work/.build/Herdling.app"
printf 'Release tooling test.\n' > "$work/.build/release-notes.md"

private="$(openssl rand -base64 32)"
public="$(printf '%s' "$private" | swift -e '
import CryptoKit
import Foundation
let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: input)!)
print(key.publicKey.rawRepresentation.base64EncodedString())
')"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public" "$work/.build/Herdling.app/Contents/Info.plist"
codesign --force --sign - "$work/.build/Herdling.app" >&2
SPARKLE_PRIVATE_KEY="$private" bash "$work/scripts/prepare-release.sh" "$tools" > "$work/output"
test "$(cat "$work/output")" = "$work/.build/release" || exit 1
test "$(find "$work/.build/release" -type f | wc -l | tr -d ' ')" = 3 || exit 1
cp "$work/.build/release/appcast.xml" "$work/expected.xml"
printf 'PASS signed archive and feed\n'

expect_failure() {
  if "$@" > "$work/failure.log" 2>&1; then
    printf 'Expected command to fail: %s\n' "$1" >&2
    exit 1
  fi
  cmp "$work/expected.xml" "$work/.build/release/appcast.xml"
}
expect_failure env SPARKLE_PRIVATE_KEY="$private" RELEASE_TAG=v999.0.0 bash "$work/scripts/prepare-release.sh" "$tools"
printf 'PASS mismatched tag preserves output\n'
/usr/libexec/PlistBuddy -c 'Set :SUVerifyUpdateBeforeExtraction false' "$work/.build/Herdling.app/Contents/Info.plist"
codesign --force --sign - "$work/.build/Herdling.app" >&2
expect_failure env SPARKLE_PRIVATE_KEY="$private" bash "$work/scripts/prepare-release.sh" "$tools"
/usr/libexec/PlistBuddy -c 'Set :SUVerifyUpdateBeforeExtraction true' "$work/.build/Herdling.app/Contents/Info.plist"
codesign --force --sign - "$work/.build/Herdling.app" >&2
printf 'PASS invalid updater security policy preserves output\n'
expect_failure env SPARKLE_PRIVATE_KEY="$(openssl rand -base64 32)" bash "$work/scripts/prepare-release.sh" "$tools"
printf 'PASS mismatched key preserves output\n'

git -C "$work" init -q
git -C "$work" add Resources/Info.plist
git -C "$work" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Fixture version'
git -C "$work" tag previous
expect_failure env SPARKLE_PRIVATE_KEY="$private" PREVIOUS_RELEASE_TAG=previous bash "$work/scripts/prepare-release.sh" "$tools"
printf 'PASS stale build preserves output\n'
original_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$work/.build/Herdling.app/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((original_build + 1))" "$work/.build/Herdling.app/Contents/Info.plist"
codesign --force --sign - "$work/.build/Herdling.app" >&2
expect_failure env SPARKLE_PRIVATE_KEY="$private" PREVIOUS_RELEASE_TAG=previous bash "$work/scripts/prepare-release.sh" "$tools"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $original_build" "$work/.build/Herdling.app/Contents/Info.plist"
codesign --force --sign - "$work/.build/Herdling.app" >&2
printf 'PASS stale version with increased build preserves output\n'

signature="$(python3 - "$work/expected.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).find('./channel/item/enclosure').attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
PY
)"
archive="$(find "$work/.build/release" -name '*.zip')"
printf 'tampered' >> "$archive"
if printf '%s' "$private" | "$tools/sign_update" --ed-key-file - --verify "$archive" "$signature" > "$work/tamper.log" 2>&1; then
  printf 'Tampered archive passed verification\n' >&2
  exit 1
fi
printf 'PASS tampered archive rejected\n'
python3 - "$work/.build/release/appcast.xml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
original = path.read_bytes()
tampered = original.replace(b'<title>', b'<title>tampered ', 1)
assert tampered != original
path.write_bytes(tampered)
PY
if printf '%s' "$private" | "$tools/sign_update" --ed-key-file - --verify "$work/.build/release/appcast.xml" > "$work/tamper.log" 2>&1; then
  printf 'Tampered feed passed verification\n' >&2
  exit 1
fi
printf 'PASS tampered feed rejected\n'
