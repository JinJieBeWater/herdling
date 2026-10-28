#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/herdling-build-app-test-XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == build && "$2" == --build-system && "$3" == xcode ]]
[[ "$4" == --arch && "$5" == "$(uname -m)" && "$6" == -c && "$7" == release ]]
if [[ "${8:-}" == --show-bin-path ]]; then
  printf '%s\n' "$HERDLING_TEST_PRODUCT"
else
  printf 'Fake build log\n'
fi
SH
cat > "$work/bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --force && "$2" == --sign && "$3" == - ]]
[[ -f "$4/Contents/MacOS/Herdling" ]]
[[ -f "$4/Contents/Resources/KeyboardShortcuts-LICENSE.txt" ]]
touch "$HERDLING_TEST_PRODUCT/../codesign-called"
printf 'Fake signing log\n'
if [[ "$HERDLING_TEST_CASE" == sign-failure ]]; then exit 1; fi
printf 'signed\n' > "$4/Contents/signature"
SH
chmod +x "$work/bin/swift" "$work/bin/codesign"

for scenario in copy-failure sign-failure success; do
  fixture="$work/$scenario"
  app="$fixture/.build/Herdling.app"
  mkdir -p "$fixture/scripts" "$fixture/Resources" "$app/Contents/MacOS" \
    "$fixture/product/KeyboardShortcuts_KeyboardShortcuts.bundle/en.lproj"
  cp "$root/scripts/build-app.sh" "$fixture/scripts/"
  printf 'previous executable\n' > "$app/Contents/MacOS/Herdling"
  printf 'previous resource\n' > "$app/Contents/old-resource"
  cp -R "$app" "$fixture/previous.app"
  printf 'new executable\n' > "$fixture/product/Herdling"
  printf 'localized resource\n' > "$fixture/product/KeyboardShortcuts_KeyboardShortcuts.bundle/en.lproj/Localizable.strings"
  for resource in Info.plist herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt KeyboardShortcuts-LICENSE.txt; do
    printf '%s\n' "$resource" > "$fixture/Resources/$resource"
  done
  if [[ "$scenario" == copy-failure ]]; then
    rm "$fixture/Resources/KeyboardShortcuts-LICENSE.txt"
  fi

  rc=0
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    HERDLING_TEST_PRODUCT="$fixture/product" HERDLING_TEST_CASE="$scenario" PATH="$work/bin:$PATH" \
    bash "$fixture/scripts/build-app.sh" release > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?

  if [[ "$scenario" == success ]]; then
    [[ "$rc" == 0 ]]
    printf '%s\n' "$app" > "$fixture/expected-stdout"
    cmp "$fixture/expected-stdout" "$fixture/stdout"
    cmp "$fixture/product/Herdling" "$app/Contents/MacOS/Herdling"
    cmp "$fixture/Resources/Info.plist" "$app/Contents/Info.plist"
    for resource in herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt KeyboardShortcuts-LICENSE.txt; do
      cmp "$fixture/Resources/$resource" "$app/Contents/Resources/$resource"
    done
    diff -r "$fixture/product/KeyboardShortcuts_KeyboardShortcuts.bundle" \
      "$app/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"
    [[ -f "$app/Contents/signature" && ! -e "$app/Contents/old-resource" ]]
  else
    [[ "$rc" != 0 && ! -s "$fixture/stdout" ]]
    diff -r "$fixture/previous.app" "$app"
  fi
  if [[ "$scenario" == copy-failure ]]; then
    [[ ! -e "$fixture/codesign-called" ]]
  else
    [[ -f "$fixture/codesign-called" ]]
  fi
  [[ "$(find "$fixture/.build" -mindepth 1 -maxdepth 1)" == "$app" ]]
  printf 'PASS %s\n' "$scenario"
done
