#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
tools="$(cd "${1:?Usage: bash scripts/prepare-release.sh SPARKLE_BIN}" && pwd)"
app="$root/.build/Herdling.app"
repo="${GITHUB_REPOSITORY:-JinJieBeWater/herdling}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY must contain the Sparkle signing seed}"
test -s .build/release-notes.md
bash scripts/verify-app-packaging.sh --app "$app" >&2

version="$(python3 - "$app/Contents/Info.plist" "$repo" <<'PY'
import base64, os, plistlib, re, subprocess, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
version, build = p['CFBundleShortVersionString'], p['CFBundleVersion']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Invalid release version'
assert re.fullmatch(r'[1-9][0-9]*', build), 'Build must be a positive integer'
assert os.environ.get('RELEASE_TAG', 'v' + version) == 'v' + version, 'Tag does not match app version'
assert p['SUFeedURL'] == f'https://github.com/{sys.argv[2]}/releases/latest/download/appcast.xml'
assert p['SURequireSignedFeed'] is True, 'The app must require signed feeds'
assert len(base64.b64decode(p['SUPublicEDKey'], validate=True)) == 32, 'Invalid update public key'
previous = os.environ.get('PREVIOUS_RELEASE_TAG')
if previous:
    old = plistlib.loads(subprocess.check_output(['git', 'show', previous + ':Resources/Info.plist']))
    assert int(build) > int(old['CFBundleVersion']), 'Build must increase over the latest release'
    assert tuple(map(int, version.split('.'))) > tuple(map(int, old['CFBundleShortVersionString'].split('.'))), 'Version must increase over the latest release'
print(version)
PY
)"

work="$(mktemp -d "$root/.build/herdling-release-XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/archives" "$work/published"
archive="Herdling-$version-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/archives/$archive"
python3 - .build/release-notes.md "$work/archives/${archive%.zip}.html" <<'PY'
import html, pathlib, sys
pathlib.Path(sys.argv[2]).write_text('<pre>' + html.escape(pathlib.Path(sys.argv[1]).read_text()) + '</pre>')
PY
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
  --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  "$work/archives" >&2
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$work/archives/appcast.xml" >&2

signature="$(python3 - "$app/Contents/Info.plist" "$work/archives" "$repo" <<'PY'
import base64, pathlib, plistlib, sys, xml.etree.ElementTree as ET
p = plistlib.load(open(sys.argv[1], 'rb'))
directory = pathlib.Path(sys.argv[2])
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(directory / 'appcast.xml').findall('./channel/item')
assert len(items) == 1, 'Release feed must contain exactly one version'
item = items[0]
assert item.findtext(ns + 'version') == p['CFBundleVersion'], 'Incorrect feed build'
assert item.findtext(ns + 'shortVersionString') == p['CFBundleShortVersionString'], 'Incorrect feed version'
normalize = lambda v: tuple(map(int, v.split('.'))) + (0,) * (3 - len(v.split('.')))
assert normalize(item.findtext(ns + 'minimumSystemVersion')) == normalize(p['LSMinimumSystemVersion']), 'Incorrect minimum macOS version'
enclosure = item.find('enclosure').attrib
archive = directory / f"Herdling-{p['CFBundleShortVersionString']}-macOS-universal.zip"
assert enclosure['url'] == f"https://github.com/{sys.argv[3]}/releases/download/v{p['CFBundleShortVersionString']}/{archive.name}", 'Incorrect download URL'
assert int(enclosure['length']) == archive.stat().st_size, 'Incorrect archive length'
assert len(base64.b64decode(enclosure[ns + 'edSignature'], validate=True)) == 64, 'Missing archive signature'
print(enclosure[ns + 'edSignature'])
PY
)"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$work/archives/$archive" "$signature" >&2
cp "$work/archives/$archive" "$work/archives/appcast.xml" "$work/published/"
(cd "$work/published" && shasum -a 256 "$archive" > "$archive.sha256")

# shortcut: final directory replacement has a rename gap; release jobs use fresh checkouts.
rm -rf "$root/.build/release"
mv "$work/published" "$root/.build/release"
printf '%s\n' "$root/.build/release"
