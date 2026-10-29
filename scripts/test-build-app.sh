#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d /tmp/herdling-build-app-test-XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == build && "$2" == --scratch-path && "$3" == "$HERDLING_TEST_FIXTURE/.build/packaging-build" ]] || exit 1
[[ "$4" == --build-system && "$5" == xcode && "$6" == -c && "$7" == release ]] || exit 1
[[ "$8" == --arch && "$9" == arm64 && "${10}" == --arch && "${11}" == x86_64 ]] || exit 1
if [[ "${12:-}" == --show-bin-path ]]; then
  printf '%s\n' "$HERDLING_TEST_PRODUCT"
else
  printf 'Fake build log\n'
  [[ "$HERDLING_TEST_CASE" != build-failure ]] || exit 1
fi
SH
cat > "$work/bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --force ]]; then
  [[ "$2" == --sign && "$3" == - ]] || exit 1
  [[ -f "$4/Contents/MacOS/Herdling" && -f "$4/Contents/Resources/Sparkle-LICENSE.txt" ]] || exit 1
  touch "$HERDLING_TEST_FIXTURE/codesign-called"
  printf 'Fake signing log\n'
  [[ "$HERDLING_TEST_CASE" != sign-failure ]] || exit 1
  printf 'signed\n' > "$4/Contents/signature"
  if [[ "$HERDLING_TEST_CASE" == resource-corruption ]]; then
    printf 'corrupt\n' > "$4/Contents/Resources/Sparkle-LICENSE.txt"
  fi
else
  [[ "$1" == --verify ]] || exit 1
  [[ "$HERDLING_TEST_CASE" != verify-failure ]] || exit 1
fi
SH
cat > "$work/bin/lipo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -x "$1" && "$2" == -verify_arch && ( "$3" == arm64 || "$3" == x86_64 ) ]] || exit 1
if [[ "$HERDLING_TEST_CASE" == architecture-failure && "$1" == */Installer ]]; then exit 1; fi
SH
cat > "$work/bin/otool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -l ]]; then
  printf '          cmd LC_RPATH\n      cmdsize 48\n         path @executable_path/../Frameworks (offset 12)\n'
  if [[ "$HERDLING_TEST_CASE" == rpath-failure && "$2" == */Updater ]]; then
    printf '          cmd LC_RPATH\n      cmdsize 99\n         path /tmp/.build/products (offset 12)\n'
  fi
else
  [[ "$1" == -L ]] || exit 1
  printf '\t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.6.0, current version 2.10.1)\n'
fi
SH
cat > "$work/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$HERDLING_TEST_CASE" == publish-failure && "$1" == */herdling-app-*/Herdling.app ]]; then exit 1; fi
exec /bin/mv "$@"
SH
chmod +x "$work/bin/"*

for scenario in build-failure copy-failure sign-failure architecture-failure rpath-failure missing-helper broken-symlink verify-failure resource-corruption publish-failure success; do
  fixture="$work/$scenario"
  app="$fixture/.build/Herdling.app"
  mkdir -p "$fixture/scripts" "$fixture/Resources" "$app/Contents/MacOS" "$fixture/product"
  cp "$root/scripts/"{build-app,verify-app-packaging}.sh "$fixture/scripts/"
  printf 'previous executable\n' > "$app/Contents/MacOS/Herdling"
  printf 'previous resource\n' > "$app/Contents/old-resource"
  cp -R "$app" "$fixture/previous.app"
  printf 'new executable\n' > "$fixture/product/Herdling"
  chmod +x "$fixture/product/Herdling"
  framework="$fixture/.build/packaging-build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  version="$framework/Versions/B"
  mkdir -p "$version/Resources" "$version/Updater.app/Contents/MacOS"
  for service in Downloader Installer; do
    mkdir -p "$version/XPCServices/$service.xpc/Contents/MacOS"
    printf '%s\n' "$service" > "$version/XPCServices/$service.xpc/Contents/MacOS/$service"
    chmod +x "$version/XPCServices/$service.xpc/Contents/MacOS/$service"
  done
  for executable in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater; do
    printf '%s\n' "$executable" > "$version/$executable"
    chmod +x "$version/$executable"
  done
  ln -s B "$framework/Versions/Current"
  for link in Sparkle Resources Autoupdate Updater.app XPCServices; do
    ln -s "Versions/Current/$link" "$framework/$link"
  done
  for resource in Info.plist herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt Sparkle-LICENSE.txt; do
    printf '%s\n' "$resource" > "$fixture/Resources/$resource"
  done
  if [[ "$scenario" == copy-failure ]]; then
    rm "$fixture/Resources/Herdr-LICENSE.txt"
  elif [[ "$scenario" == missing-helper ]]; then
    rm "$version/Autoupdate"
  elif [[ "$scenario" == broken-symlink ]]; then
    rm "$framework/Versions/Current"
    ln -s missing "$framework/Versions/Current"
  fi

  rc=0
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    HERDLING_TEST_FIXTURE="$fixture" HERDLING_TEST_PRODUCT="$fixture/product" HERDLING_TEST_CASE="$scenario" PATH="$work/bin:$PATH" \
    bash "$fixture/scripts/build-app.sh" release > "$fixture/stdout" 2> "$fixture/stderr" || rc=$?

  if [[ "$scenario" == success ]]; then
    if [[ "$rc" != 0 ]]; then cat "$fixture/stderr" >&2; exit 1; fi
    printf '%s\n' "$app" > "$fixture/expected-stdout"
    cmp "$fixture/expected-stdout" "$fixture/stdout"
    cmp "$fixture/product/Herdling" "$app/Contents/MacOS/Herdling"
    cmp "$fixture/Resources/Info.plist" "$app/Contents/Info.plist"
    for resource in herdr-mark.svg THIRD_PARTY_NOTICES.md Herdr-LICENSE.txt Sparkle-LICENSE.txt; do
      cmp "$fixture/Resources/$resource" "$app/Contents/Resources/$resource"
    done
    [[ -f "$app/Contents/signature" && ! -e "$app/Contents/old-resource" ]] || exit 1
    diff -r --no-dereference "$framework" "$app/Contents/Frameworks/Sparkle.framework"
    [[ -L "$app/Contents/Frameworks/Sparkle.framework/Versions/Current" ]] || exit 1
  else
    [[ "$rc" != 0 && ! -s "$fixture/stdout" ]] || exit 1
    if ! diff -r "$fixture/previous.app" "$app"; then
      cat "$fixture/stderr" >&2
      exit 1
    fi
  fi
  if [[ "$scenario" == copy-failure || "$scenario" == build-failure ]]; then
    [[ ! -e "$fixture/codesign-called" ]] || exit 1
  else
    [[ -f "$fixture/codesign-called" ]] || exit 1
  fi
  [[ -z "$(find "$fixture/.build" -maxdepth 1 -name 'herdling-app-*' -print)" ]] || exit 1
  printf 'PASS %s\n' "$scenario"
done
