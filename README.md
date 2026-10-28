# Herdling

[English](README.md) | [简体中文](README.zh-CN.md)

Herdling is a macOS menu bar companion for [Herdr](https://herdr.dev/). It shows local and SSH-hosted Herdr agents, keeps their status current, and opens the selected session in [Ghostty](https://ghostty.org/) or [Kero](https://kero.sh/).

## Features

- Groups agents by machine, session, Space, and worktree while preserving Herdr order.
- **Activity** prioritizes agents by status: blocked, done, working, then the three most recently updated idle agents. **Sources** opens the full directory; expand one source or keep them all closed.
- Keeps rows in place while browsing, with live status; reopen to rebuild the list. Failed jumps retain their target for retry.
- Updates local and remote sessions through Herdr's socket event stream, with discovery and CLI fallback where needed.
- Choose Ghostty or Kero in Settings; the choice is saved. Reuses a matching Herdr client in that terminal, or creates and verifies a new one. Ghostty keeps its Tab/Window setting; Kero opens new sessions.
- Reads SSH hosts from `~/.ssh/config`, including `Include` files.
- Supports Launch at Login, keyboard shortcuts, VoiceOver labels, light/dark appearance, and Reduce Motion.

## Requirements

- macOS 15 or later
- Swift 6.2 toolchain (only when building from source)
- [Herdr](https://herdr.dev/) installed locally and on each enabled SSH host
- [Ghostty](https://ghostty.org/) or [Kero](https://kero.sh/) with its `kero` CLI for opening and focusing sessions
- Key-based or otherwise non-interactive SSH access for remote hosts

Herdling finds `herdr` through `HERDR_BIN_PATH` or common Homebrew/system paths. It finds `kero` through `KERO_BIN_PATH`, common Homebrew paths, or the Kero app bundle. Remote commands run through the host's login shell.

## Build and run

Check [Releases](https://github.com/JinJieBeWater/herdling/releases) for binary builds: choose `arm64` for Apple Silicon or `x86_64` for Intel. Extract `Herdling.app` and move it to `/Applications`. Each ZIP has a `.sha256` file; verify it with `shasum -a 256 -c <filename>.zip.sha256` from the download directory.

These builds use ad-hoc signing, without an Apple Developer ID certificate or notarization. macOS may block the first launch. After attempting to open the app, use **System Settings → Privacy & Security → Open Anyway** only if you trust the download. Do not disable Gatekeeper system-wide.

To build from source:

```bash
git clone https://github.com/JinJieBeWater/herdling.git
cd herdling
bash scripts/build-app.sh release
open .build/Herdling.app
```

The script creates an ad-hoc-signed app at `.build/Herdling.app`. Move it to a stable location such as `/Applications` before enabling Launch at Login.

For a development build:

```bash
bash scripts/build-app.sh
open .build/Herdling.app
```

## Setup

1. Start at least one Herdr session.
2. Open Herdling from the menu bar.
3. Open **Settings** with `⌘,` or by right-clicking the menu bar item.
4. Enable required aliases under **SSH Sources**.
5. Under **Terminal → Application**, choose **Ghostty** or **Kero**. The default remains Ghostty; switching only affects subsequent jumps, not existing terminal sessions.
6. Optionally record a global panel shortcut in Settings. No combination is assigned by default.

Ghostty uses AppleScript Automation; allow Herdling to control Ghostty when macOS asks, and choose Tab or Window for new clients. Kero uses its native CLI, with no Automation permission or Tab/Window setting. Settings checks only the selected terminal.

### Remote hosts

Herdling uses named `Host` entries from `~/.ssh/config`. Wildcard and negated entries are ignored. Each enabled host must:

- connect without an interactive password prompt;
- expose `herdr` through its login shell;
- provide `nc` with Unix-domain socket support.

Check the connection before enabling it:

```bash
ssh -o BatchMode=yes my-server '$SHELL -lc "herdr session list --json"'
```

## Controls

| Action | Result |
| --- | --- |
| Left-click menu bar item | Open or close roster |
| Right-click menu bar item | Open Refresh/Settings/Quit menu |
| Click a machine in Sources | Toggle its directory; expanding one closes the previous source |
| Click an agent, worktree, Space, or session | Focus it in the selected terminal |
| Global panel shortcut (when configured) | Toggle panel; select a target without navigating |
| `↑` / `↓` | Select a row without navigating |
| `Enter` | Open selected target; source rows only toggle their directory |
| `←` / `→` in Sources | Return to parent / collapse or expand a source |
| `Tab` / `Shift-Tab` | Move among native controls |
| `⌘,` | Open Settings |
| `Esc` in roster | Close panel |
| `⌘Q` | Quit Herdling |

Herdr focus can mark every pane in the destination tab as seen and affect all shell clients in that session. A failed jump may already have changed focus; it does not imply rollback or that a task was handled. Recent idle rows come from Herdr's state timestamps, not navigation history.

## Development

Run tests:

```bash
swift test
```

Treat warnings as errors:

```bash
swift test -Xswiftc -warnings-as-errors
```

Build release app:

```bash
bash scripts/build-app.sh release
```

### Releases

`.github/workflows/release.yml` tests, builds and verifies app packaging for Apple Silicon and Intel on pushes to `main`, pull requests to `main`, and manual runs. These runs upload ZIPs and SHA-256 files as Actions artifacts without publishing a release. Xcode 26.2 is selected explicitly for Swift 6.2 and the macOS 26 APIs.

To publish, set `CFBundleShortVersionString` in `Resources/Info.plist` to the release version and increment `CFBundleVersion` for subsequent releases. Commit and push the changes, including the workflow, then tag that commit:

```bash
git tag -a v0.1.0 -m 'Herdling 0.1.0'
git push origin v0.1.0
```

Use `v<CFBundleShortVersionString>` for the tag; a mismatch fails the build. After both architectures pass, the workflow creates a GitHub Release with both ZIPs, checksums and generated release notes. It only needs the automatic `GITHUB_TOKEN`; no Apple certificates or repository secrets are required. Do not create the Release manually first or move an existing release tag; use a new version for corrections.

### Architecture

- AppKit owns `NSStatusItem` and a nonactivating `NSPanel`; SwiftUI renders panel content.
- Local and remote monitors maintain one NDJSON socket stream per Herdr session.
- Periodic discovery finds added or removed sessions. CLI polling remains a fallback when a stream is unavailable.
- Ghostty activation retains AppleScript and terminal/process validation. Kero activation uses `kero ls --json`, pane process ancestry and `kero focus`; new clients use `kero new`. Each backend verifies its own client, without falling back to another terminal.

## Troubleshooting

- **No local sessions:** confirm `herdr session list --json` works in a new shell. Set `HERDR_BIN_PATH` if Herdr is installed elsewhere.
- **SSH source stays offline:** run the BatchMode command above. Fix host keys, authentication, remote `PATH`, or missing `nc` before retrying.
- **Kero does not open or focus:** open Kero and check `kero ls --json`. Set `KERO_BIN_PATH` if Kero is installed elsewhere. If a new client fails to start, check Herdr and SSH before retrying; failed sessions are not automatically deleted.
- **Ghostty does not open or focus:** check **System Settings → Privacy & Security → Automation** and allow Herdling to control Ghostty.
- **Launch at Login is unavailable:** run Herdling from `.build/Herdling.app` or another app bundle, not through `swift run`.

## License

Herdling itself does not currently declare a software license. The bundled Herdr mark is covered by [third-party notices](Resources/THIRD_PARTY_NOTICES.md) and the bundled [Apache License 2.0 text](Resources/Herdr-LICENSE.txt).
