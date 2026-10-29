# Herdling

[English](README.md) | [简体中文](README.zh-CN.md)

Herdling is a macOS menu bar companion for [Herdr](https://herdr.dev/). See which agents need attention across local and SSH sessions, then jump to their terminals in [Ghostty](https://ghostty.org/) or [Kero](https://kero.sh/).

**[Download Herdling for macOS →](https://github.com/JinJieBeWater/herdling/releases/latest)** · One Universal2 app for Apple Silicon and Intel

Requires **macOS 15+**, Herdr, and **Ghostty 1.4+** or **Kero with its `kero` CLI**.

![Herdling menu bar panel showing example Herdr sessions](docs/media/herdling-overview.png)

## What it does

- **Activity** puts blocked agents first, then done, working, and the three most recently updated idle agents. Idle recency comes from Herdr's state timestamps, not your navigation history.
- **Sources** browses the full directory by machine, session, Space, and worktree in Herdr order. Expand one source at a time, or keep them all closed.
- **Terminal jumps** focus the selected agent, worktree, Space, or session. Herdling reuses a matching Herdr client in your chosen terminal, or creates and verifies a new one.
- **Local + SSH** sessions stay current through Herdr's socket event streams, with discovery and CLI fallback when needed. SSH sources come from `~/.ssh/config`, including `Include` files.

## Demo

[![Demo: Activity, jumping to Ghostty, and browsing Sources](docs/media/herdling-demo.gif)](docs/media/herdling-demo.mp4)

Watch the [23-second demo (MP4)](docs/media/herdling-demo.mp4): find a blocked task in Activity, jump to Ghostty, approve the sample change, then browse Sources and open another project. Recorded in an isolated macOS VM with scripted sample tasks; waiting time is trimmed. No real work sessions or AI inference are shown. SSH and Kero are not demonstrated.

## Install

1. Download the ZIP and its `.zip.sha256` file from the [latest release](https://github.com/JinJieBeWater/herdling/releases/latest). In the download directory, verify with `shasum -a 256 -c <filename>.zip.sha256`.
2. Extract `Herdling.app` and move it to `/Applications` before opening it or enabling Launch at Login.

> Builds are **ad-hoc signed, without Apple Developer ID or notarization**. macOS may block the first launch. After attempting to open the app, use **System Settings → Privacy & Security → Open Anyway** only if you trust the download. Do not disable Gatekeeper system-wide. System permissions may need approval again after an ad-hoc-signed update.

From **0.2.0**, right-click the menu bar icon → **Check for Updates…**. Background checks are controlled by **Settings → General → Automatically check for updates**. Sparkle verifies the signed feed and archive before installation; installing and restarting require confirmation. This does not replace Developer ID or notarization. Older releases without Sparkle need one manual installation.

## Setup

1. Start at least one Herdr session, then click Herdling in the menu bar.
2. Open **Settings** with `⌘,` or by right-clicking the menu bar icon. Under **Terminal → Application**, choose **Ghostty** (default) or **Kero**. Your choice is saved and only affects subsequent jumps.
3. **Ghostty:** allow Herdling to control Ghostty when macOS asks, keep `macos-applescript` enabled (the default), and choose Tab or Window for new clients. **Kero:** uses its native CLI; no Automation permission or Tab/Window setting is needed.
4. **Optional SSH:** enable named hosts under **SSH Sources**. Each host needs Herdr, non-interactive SSH access, and `nc` with Unix-domain socket support. See [remote setup and connection check](docs/development.md#remote-hosts).

## Controls

| Action | Result |
| --- | --- |
| Left-click menu bar icon | Open or close roster |
| Right-click menu bar icon | Open Settings, updates, and Quit menu |
| Click a machine in Sources | Toggle its directory; expanding one closes the previous source |
| Click an agent, worktree, Space, or session | Focus it in the selected terminal |
| `↑` / `↓` | Select a row without navigating |
| `Enter` | Open selected target; source rows only toggle their directory |
| `←` / `→` in Sources | Return to parent / collapse or expand a source |
| `Tab` / `Shift-Tab` | Move among native controls |
| `⌘,` | Open Settings |
| `⌘W` in Settings | Close the Settings window |
| `Esc` in roster | Close panel |
| `⌘Q` | Quit Herdling |

Herdr focus can mark every pane in the destination tab as seen and affect all shell clients in that session. A failed jump may already have changed focus; it does not imply rollback or that a task was handled.

## Development and troubleshooting

[Build from source, tests, SSH setup, architecture, release signing, and troubleshooting](docs/development.md). Source builds require Xcode 26.2+ with Swift 6.2+; Command Line Tools alone are not sufficient.

## License

Herdling itself does not currently declare a software license. See [third-party notices](Resources/THIRD_PARTY_NOTICES.md) for the bundled Herdr mark and Sparkle, including their original license texts.
