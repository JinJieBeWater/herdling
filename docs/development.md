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
- Monitors legacy Herdr and Herdr Core at the same time. Legacy local and remote sessions use socket event streams, with discovery and CLI fallback where needed. Core uses its own socket connection and machine directory.
- Choose Ghostty or Kero in Settings for legacy Herdr. It reuses a matching client or creates and verifies a new one. Core always uses native Herdr App pane focus and activation, independently of that preference. Failures do not fall through to another application.
- Supports Launch at Login, keyboard navigation, VoiceOver labels, light/dark appearance, and Reduce Motion.

Herdling finds `herdr` through `HERDR_BIN_PATH` or common Homebrew/system paths. It finds `kero` through `KERO_BIN_PATH`, common Homebrew paths, or the Kero app bundle. Remote commands run through the host's login shell.

Settings checks only the selected terminal. Kero does not use the Tab/Window setting. Debug builds do not start the updater.

## Runtime boundaries

Legacy Herdr and Core retain separate identities, connections, and health. A missing unused runtime does not make the other one offline. Matching names, folders, or short terminal IDs do not merge targets across runtimes or Core instances. A Core terminal belongs to its hosting Core; its current machine address is a route to it, not a globally unique identity.

Sources keeps the legacy Session/Space/worktree directory and adds Core terminals under their machines. Core terminals do not acquire synthetic Sessions or a Main worktree. Activity uses native Herdr App states for Core; terminals without an App status remain in Sources. One terminal is one entry, even if it carries several Core status records. A missing or unknown report is not idle, and a finished terminal process is not a done agent.

Core's raw report and Herdr App's seen-based Done/Idle are different. Core status changes arrive through `events.subscribe`. For App seen changes, Herdling watches the App's `view.json` with native filesystem notifications, then reads the App's derived states through its control socket. It also reads after a jump and on Core changes; there is no App status polling timer. This picks up a terminal viewed directly in App without a Core status event. It does not clear prompts optimistically or keep its own unread queue. If the App cannot be verified or read, Core Activity is withheld; the native Core directory remains in Sources.

The file watcher treats changes as invalidations, supports atomic replacement, and never infers agent status from file contents. `view.json` is App 0.1.10's internal persistence, not a public event API; an upstream change or failed App save can prevent a notification. Reopening Herdling restores its initial snapshot. See the [source investigation](herdr-app-seen-events.md).

Observation connects only to existing Core and App endpoints; it launches neither. An explicit Core jump may launch Herdr App, whose own startup may start Core. Herdling does not run an attach client in Ghostty or Kero for Core targets.

Herdr App's control endpoint is `$HERDR_APP_HOME/herdr-app.sock`, defaulting to `~/.config/herdr-app/herdr-app.sock`. In App 0.1.10, IPC does not expose CoreID. Herdling instead checks native peer process IDs and the App's immediate Core connector's actual Unix socket links to the selected Core server. Matching short terminal IDs or configured paths alone are not sufficient. A jump validates the Core target, focuses its existing App pane, raises the App, and reads back the selected space/tab/pane/terminal and actual foreground application.

Endpoint discovery honors `HC_SOCKET`, `HC_SESSION`, XDG paths, and Core's top-level `socket` setting. The config reader supports single-line quoted socket strings; unsupported TOML forms fail visibly and require an explicit `HC_SOCKET`. Initial ordering uses Core status times; later App state transitions use their observation time because App does not publish timestamps. Repeated identical App snapshots do not advance idle recency. Machine health can lag by the 15-second local refresh interval.

Core navigation follows [App 0.1.10](https://github.com/herdrdev/herdr-app/tree/v0.1.10)'s native `pane.focus` and seen behavior. A terminal without an existing App pane fails clearly; Herdling does not label a background worker, create a pane, or change App layouts to reveal it. App does not expose its rendered visibility tree, so intentionally hidden/custom layouts retain App's own behavior rather than a separate Herdling visibility rule.

## Remote hosts

**SSH Sources controls legacy Herdr only.** Changing those selections does not add, remove, or disconnect Core machines. Core uses the machines already configured in Core; manage those through Core's own tools.

For legacy sessions, Herdling uses named `Host` entries from `~/.ssh/config`. Wildcard and negated entries are ignored. Each enabled host must:

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
- Legacy local and remote monitors maintain one NDJSON socket stream per Herdr session. Periodic discovery finds added or removed sessions; CLI polling remains a fallback when a stream is unavailable.
- Core has a separate lifecycle/machine monitor and terminal directory. Identity includes the hosting Core ID and native terminal ID; an independent native App observer supplies its derived activity states and focus path.
- Ghostty matches its native AppleScript `tty` to the legacy client process, then focuses the stable terminal ID. It does not change titles or save terminal mappings. Kero uses `kero ls --json`, pane ancestry and `kero focus`; new legacy clients use `kero new`. Neither handles Core targets.

## Troubleshooting

- **No legacy local sessions:** confirm `herdr session list --json` works in a new shell. Set `HERDR_BIN_PATH` if legacy Herdr is installed elsewhere.
- **Legacy SSH source stays offline:** run the BatchMode command above. Fix host keys, authentication, remote `PATH`, or missing `nc` before retrying.
- **Core source is unavailable:** check that the Core you intend to monitor is already running and that its machines are connected. Legacy SSH Sources selections do not repair a Core connection. A terminal without a status report belongs in Sources, so an empty Activity list does not by itself mean Core is offline.
- **Core status or focus is unavailable:** open Herdr App connected to the same Core and check `herdr-app ls` / `herdr-app status`. A terminal needs an existing App pane. A different App Core, an unreadable native binding, or missing pane is an error, not a reason to open Kero. Check `HERDR_APP_HOME` when using a non-default App profile.
- **Kero does not open or focus:** open Kero and check `kero ls --json`. Set `KERO_BIN_PATH` if Kero is installed elsewhere. Check the legacy Herdr connection before retrying; failed sessions are not automatically deleted.
- **Ghostty does not open or focus:** check **System Settings → Privacy & Security → Automation** and allow Herdling to control Ghostty.
- **Launch at Login is unavailable:** run Herdling from `.build/Herdling.app` or another app bundle, not through `swift run`.
