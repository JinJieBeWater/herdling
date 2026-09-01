# Ghostty macOS automation after 1.3.1

Checked 2026-08-30 while selecting Herdling's client-creation path.

## Conclusion

- Ghostty 1.3.1 is latest stable and reproduces empty AppleScript-created terminals locally: the object exists, but `input text` fails with `Terminal surface model is not available. (-10000)`.
- Current `main`/tip has no demonstrated fix. Its core AppleScript window/tab creation files are byte-identical to v1.3.1. Tip was not installed for a runtime test.
- Exact focus by a stored terminal UUID works. Tab creation cannot return causal identity, while `new window with configuration` currently returns an exact terminal and applies `initial input` reliably.

## Local results on Ghostty 1.3.1

Failed with an empty `👻` terminal and no surface model:

- `new tab in front window`
- `new window with configuration {command: ...}`
- `open -na Ghostty --args -e ...`

Delays, activation, focus, tab selection, `initial input`, and `command` did not make the terminal writable.

Working:

- `new window with configuration` plus `initial input`; live retest returned the exact terminal UUID in 268 ms and executed input in 492 ms
- direct focus by a stored terminal UUID
- focus Herdr pane after activating its exact Ghostty terminal

## Upstream status

- [Issue #12730](https://github.com/ghostty-org/ghostty/issues/12730) documents the same 1.3.1 regression and says 1.3.0 worked.
- The issue was closed automatically by `ghostty-vouch`, not triaged or fixed.
- [Official AppleScript docs](https://ghostty.org/docs/features/applescript) still document the affected API.
- [Tip release](https://github.com/ghostty-org/ghostty/releases/tag/tip) follows `main`; no newer stable release exists.
- `AppDelegate+AppleScript.swift` and `ScriptTab.swift` are byte-identical between v1.3.1 and `main`, so source provides no evidence that tip fixes surface creation.
- Main adds terminal `pid` and `tty` through [PR #11922](https://github.com/ghostty-org/ghostty/pull/11922). This improves exact mapping but does not repair creation.

## How other projects handle it

- [`keefar/ticket-flow`](https://github.com/keefar/ticket-flow) detected 1.3.1, changed spawn to an opt-in/fallback path, then removed Ghostty spawning entirely.
- Raycast Ghostty integrations and CodexBar still call `new window`/`new tab` with surface configuration. They do not prove the path works reliably on 1.3.1; no live regression guard was found.
- Some scripts use `split` from an existing live terminal. This cannot create the first Client for a Herdr Session.
- GUI keystroke automation (`System Events`, ⌘T/⌘N) works around the scripting API but requires Accessibility permission, outside Herdling's locked MVP scope.
- Ghostty App Intents/Shortcuts can create terminals on macOS 15+, but require Shortcut setup and are not directly callable through `shortcuts run` without a user-created shortcut.
- Pinning Ghostty 1.3.0 is the only reported way to retain the affected native tab-creation path without Accessibility.

## Herdling decision

Herdling creates every managed Client with one `new window with configuration` transaction. It sets `initial input` before creation, receives the returned window's selected terminal UUID, and persists that UUID. Existing Clients use direct UUID focus. Missing mappings create a fresh managed window instead of guessing through process/TTY/OSC title probes.

Tab/Window selection was removed: Ghostty 1.3 tab automation cannot prove which concurrently created tab belongs to Herdling. Accessibility Cmd-T plus snapshot polling reduced failures but could not establish causality. The window path removes Accessibility, ambiguity errors, fixed readiness waits, and repeated `osascript` probes.

Live KVM verification after the change produced the window in 0.56 s and the local Herdr remote process in 1.53 s, including an external AX click command. Reusing an existing mapping focused the exact UUID without creating another process. The attach command clears inherited `HERDR_ENV`/pane/socket variables so a Ghostty process launched from an existing Herdr environment does not trigger Herdr's nested-client guard.

Do not silently claim success when a Ghostty terminal object has no surface model.
