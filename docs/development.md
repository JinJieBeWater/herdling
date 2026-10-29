# Development and troubleshooting

[English](development.md) | [简体中文](development.zh-CN.md) · [Back to Herdling](../README.md)

## Build from source

Requires macOS 15 or later and Xcode 26.2 or later with Swift 6.2 or later. Command Line Tools alone are not sufficient.

```bash
git clone https://github.com/JinJieBeWater/herdling.git
cd herdling
bash scripts/build-app.sh release
open .build/Herdling.app
```

The script creates an ad-hoc-signed Universal2 app at `.build/Herdling.app`, including the complete Sparkle runtime. Move it to a stable location such as `/Applications` before enabling Launch at Login.

For a development build:

```bash
bash scripts/build-app.sh
open .build/Herdling.app
```

## Runtime behavior

- Keeps rows in place while browsing, with live status; reopen to rebuild the list. Failed jumps retain their target for retry.
- Updates local and remote sessions through Herdr's socket event stream, with discovery and CLI fallback where needed.
- Choose Ghostty or Kero in Settings; the choice is saved. Reuses a matching Herdr client in that terminal, or creates and verifies a new one. Ghostty keeps its Tab/Window setting; Kero opens new sessions.
- Supports Launch at Login, keyboard navigation, VoiceOver labels, light/dark appearance, and Reduce Motion.

Herdling finds `herdr` through `HERDR_BIN_PATH` or common Homebrew/system paths. It finds `kero` through `KERO_BIN_PATH`, common Homebrew paths, or the Kero app bundle. Remote commands run through the host's login shell.

Settings checks only the selected terminal. Kero does not use the Tab/Window setting. Debug builds do not start the updater.

## Remote hosts

Herdling uses named `Host` entries from `~/.ssh/config`. Wildcard and negated entries are ignored. Each enabled host must:

- connect without an interactive password prompt;
- expose `herdr` through its login shell;
- provide `nc` with Unix-domain socket support.

Check the connection before enabling it:

```bash
ssh -o BatchMode=yes my-server '$SHELL -lc "herdr session list --json"'
```

## Tests

Run tests:

```bash
bash scripts/test-build-app.sh
swift test --no-parallel
```

## Releases

`.github/workflows/release.yml` tests, builds and verifies one Universal2 app on pushes to `main`, pull requests to `main`, and manual runs. It uploads the app ZIP as an Actions artifact without publishing a release. The macOS runner uses Xcode 26.2 for Swift 6.2 and the macOS 26 APIs. Intel code is cross-compiled and checked for architecture, signatures and relocatable dependencies; CI does not execute it on an Intel Mac.

CI runs the complete automated suite and packaging failure checks. Release tooling also signs and verifies a test feed and archive with an ephemeral key, checks tag/key/version failures, and rejects modified archives and feed content. PR builds never receive the production signing key. Pixel and OCR checks are not part of the suite; use an isolated desktop for real update and navigation checks.

Maintainers must configure the repository secret **`SPARKLE_PRIVATE_KEY`** with the private seed exported by Sparkle's official `generate_keys` tool. Its public key must match `SUPublicEDKey` in `Resources/Info.plist`. Tools are pinned to the package version and a SHA-256 checksum by `scripts/fetch-sparkle-tools.sh`. For this repository the key is stored in the maintainer's Keychain under account `dev.herdr.Herdling`; keep a secure backup outside the repository. Never commit the private key or upload it as an artifact. No Apple certificate or notarization credentials are used by this release path.

To publish, set `CFBundleShortVersionString` in `Resources/Info.plist` to the release version and increment `CFBundleVersion` for subsequent releases. Commit and push the changes, including the workflow, then tag that commit:

```bash
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
git tag -a "v$version" -m "Herdling $version"
git push origin "v$version"
```

Use `v<CFBundleShortVersionString>` for the tag. Both the version and build must exceed the latest release. A serialized macOS release job restores the verified app, generates notes, then runs `scripts/prepare-release.sh` to create the ZIP, checksum and signed `appcast.xml` in `.build/release`. The job uploads all three assets to a draft, checks their names and sizes, and only then publishes it as Latest. Missing keys or failed checks stop publication; there is no unsigned fallback. Do not create the Release manually first or move an existing release tag; use a new version for corrections.

The fixed feed is `https://github.com/JinJieBeWater/herdling/releases/latest/download/appcast.xml`. Each feed contains only the current release and points to an immutable, tagged ZIP URL. There are no per-architecture feeds, old-package synchronization or delta updates.

## Architecture

- AppKit owns `NSStatusItem` and a nonactivating `NSPanel`; SwiftUI renders panel content.
- Local and remote monitors maintain one NDJSON socket stream per Herdr session.
- Periodic discovery finds added or removed sessions. CLI polling remains a fallback when a stream is unavailable.
- Ghostty matches its native AppleScript `tty` to the Herdr client process, then focuses the stable terminal ID. It does not change terminal titles or save terminal mappings. Kero uses `kero ls --json`, pane process ancestry and `kero focus`; new clients use `kero new`. Each backend verifies its own client, without falling back to another terminal.

## Troubleshooting

- **No local sessions:** confirm `herdr session list --json` works in a new shell. Set `HERDR_BIN_PATH` if Herdr is installed elsewhere.
- **SSH source stays offline:** run the BatchMode command above. Fix host keys, authentication, remote `PATH`, or missing `nc` before retrying.
- **Kero does not open or focus:** open Kero and check `kero ls --json`. Set `KERO_BIN_PATH` if Kero is installed elsewhere. If a new client fails to start, check Herdr and SSH before retrying; failed sessions are not automatically deleted.
- **Ghostty does not open or focus:** check **System Settings → Privacy & Security → Automation** and allow Herdling to control Ghostty.
- **Launch at Login is unavailable:** run Herdling from `.build/Herdling.app` or another app bundle, not through `swift run`.
