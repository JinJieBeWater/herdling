# Herdling

[English](README.md) | [简体中文](README.zh-CN.md)

Herdling is a macOS menu bar companion for [Herdr](https://herdr.dev/). It shows local and SSH-hosted Herdr agents, keeps their status current, and opens the selected session in [Ghostty](https://ghostty.org/).

## Features

- Groups agents by machine, session, Space, and worktree while preserving Herdr order.
- Shows blocked, completed, working, and recently idle agents in **Recent**. Idle entries remain there for 10 minutes.
- Updates local and remote sessions through Herdr's socket event stream, with discovery and CLI fallback where needed.
- Reuses an existing Ghostty Herdr client when possible. New clients open in a tab by default; Settings can switch this to a window.
- Reads SSH hosts from `~/.ssh/config`, including `Include` files.
- Supports Launch at Login, keyboard shortcuts, VoiceOver labels, light/dark appearance, and Reduce Motion.

## Requirements

- macOS 14 or later
- Swift 6.2 toolchain
- [Herdr](https://herdr.dev/) installed locally and on each enabled SSH host
- [Ghostty](https://ghostty.org/) for opening and focusing sessions
- Key-based or otherwise non-interactive SSH access for remote hosts

Herdling finds `herdr` through `HERDR_BIN_PATH` or common Homebrew/system paths. Remote commands run through the host's login shell.

## Build and run

There are no signed or notarized binary releases yet. Build the app from source:

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
5. Choose whether new Ghostty clients open as tabs or windows.

The first Ghostty action may trigger a macOS Automation permission prompt. Permission status appears in Settings.

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
| Right-click menu bar item | Open Settings/Quit menu |
| Click Recent or a machine | Expand that section and collapse the previous one |
| Click an agent, worktree, Space, or session | Focus it in Ghostty |
| `⌘,` | Open Settings |
| `Esc` | Return from Settings, then close panel |
| `⌘Q` | Quit Herdling |

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

### Architecture

- AppKit owns `NSStatusItem` and a nonactivating `NSPanel`; SwiftUI renders panel content.
- Local and remote monitors maintain one NDJSON socket stream per Herdr session.
- Periodic discovery finds added or removed sessions. CLI polling remains a fallback when a stream is unavailable.
- Ghostty activation uses AppleScript plus terminal/process validation to reuse the correct client and avoid duplicate tabs or windows.

## Troubleshooting

- **No local sessions:** confirm `herdr session list --json` works in a new shell. Set `HERDR_BIN_PATH` if Herdr is installed elsewhere.
- **SSH source stays offline:** run the BatchMode command above. Fix host keys, authentication, remote `PATH`, or missing `nc` before retrying.
- **Ghostty does not open or focus:** check **System Settings → Privacy & Security → Automation** and allow Herdling to control Ghostty.
- **Launch at Login is unavailable:** run Herdling from `.build/Herdling.app` or another app bundle, not through `swift run`.

## License

Herdling itself does not currently declare a software license. The bundled Herdr mark is covered by [third-party notices](Resources/THIRD_PARTY_NOTICES.md) and the bundled [Apache License 2.0 text](Resources/Herdr-LICENSE.txt).
