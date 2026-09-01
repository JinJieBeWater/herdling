# Research: SwiftUI/AppKit macOS Menu Bar Utility — Best Practices & Herdling Audit

Audit date: 2026-09-01. Code read: `Package.swift`, `scripts/build-app.sh`, `Resources/Info.plist`, and `Sources/Herdling/*.swift` (App, StatusItemController, MenuBarStatusItem, PanelOutsideClickMonitor, SessionStore, AgentListView, HerdrClient, GhosttyController, HerdrBrand, SSHConfig, GitBranchResolver, CommandRunner, SourceDescriptor).

## Summary

Herdling's architecture (NSStatusItem + custom nonactivating NSPanel + hosted SwiftUI) is already the right call for a data-rich, resizable menu bar panel — `MenuBarExtra` window style and `NSPopover` both have documented defects (uncontrollable resize timing, dismiss bugs, popover re-anchoring) that Herdling's custom panel sidesteps. Follow-up implementation now uses Herdr's socket snapshot/event stream (`session.snapshot` + `events.subscribe`) for local Sources, retains polling with exponential backoff for SSH Sources, installs standard Cmd+,/Cmd+Q commands, prevents duplicate instances, and renders status items at their actual display scale. Distribution is partially implemented (`build-app.sh` creates an ad-hoc-signed `.app`) but still lacks Developer ID signing, notarization, packaging, and updates.

## Findings

### Architecture: MenuBarExtra vs NSStatusItem + NSPanel

1. **NSStatusItem + custom NSPanel is the right primitive for Herdling; MenuBarExtra is not worth copying — [already implemented, keep]** — `MenuBarExtra` (macOS 13+) is the SwiftUI default for simple menus, but its `.window` style hides resize timing: "any view-level change that alters the popover's intrinsic content size races AppKit's own resize animation… visible as a tiny flicker when a session group is collapsed". A maintainer replaced MenuBarExtra(.window) with NSStatusItem + NSPanel for exactly that reason. [Irrlicht issue #189](https://github.com/ingo-eichhorst/Irrlicht/issues/189) Also documented: `isMenuPresented` inverts when dismissing by clicking another window in the same app [orchetect/MenuBarExtraAccess #14](https://github.com/orchetect/MenuBarExtraAccess/issues/14), sheets inside a window-style MenuBarExtra dismiss the whole popover [StackOverflow](https://stackoverflow.com/questions/78835562/opening-a-sheet-inside-a-menubarextra), and ScrollView content height regresses between opens on macOS 14 [StackOverflow](https://stackoverflow.com/questions/77487268/swiftui-menubarextra-with-window-style-layout-issue-with-scrollview). Third-party fixups exist (FluidMenuBarExtra) but add a dependency to fix what the custom panel already does. [FluidMenuBarExtra](https://github.com/wadetregaskis/FluidMenuBarExtra) Herdling's `StatusItemController.swift` holds a strong ref to the status item (docs-flagged silent-disappearance trap) and manages panel geometry itself — correct. [Apple MenuBarExtra docs](https://developer.apple.com/documentation/swiftui/menubarextra) · [Barkeep: what the docs don't tell you](https://barkeepmac.com/build-macos-menu-bar-app-swift.html)

2. **NSPopover re-anchors on every contentSize change — Herdling's NSPanel choice avoids a known defect — [already implemented, keep]** — NSPopover position is derived from anchor rect + contentSize; changing contentSize while shown recomputes position from the status button's screen coords and "ends up being wrong almost every time in a status bar context", causing side-jumping on resize. [runner-bar issue #377](https://github.com/eoncode/runner-bar/issues/377) · [Apple NSPopover docs](https://developer.apple.com/documentation/appkit/nspopover) Herdling resizes the panel with explicit frame math (`resizedVisiblePanelFrame`, `clampedContentHeight` in `StatusItemController.swift`) — no re-anchor problem. Good.

3. **HIG: menu bar extras — symbol, menu-not-popover, user decides — [partially applicable; one deliberate deviation]** — HIG guidance for menu bar extras: use a symbol; *display a menu, not a popover, when people click your menu bar extra*; let people decide whether it appears; don't rely on its presence; expose functionality other ways. [Apple HIG: The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) Herdling's left-click opens a data-rich panel (a popover-equivalent) — a deliberate, common exception for status/roster UIs (Itsycal, iStat Menus pattern), and the right-click context menu plus Quit already provides the menu path. Low priority: consider a "Show as menu" fallback for accessibility-first users; at minimum keep the context menu (already present).

### Panel geometry and icon

4. **Panel geometry already handles screens/notch correctly — [already implemented]** — Herdling clamps panel origin and height to `screen.visibleFrame` with margins (`panelOrigin`, `panelSize`, `availablePanelHeight` in `StatusItemController.swift`), which keeps the panel off the notch area and below the menu bar. Menu bar extras render in a fixed 22pt working area; a 16×16 symbol matches system weight. Herdling's icon is a template strip sized `ceil(width)+10` — within guidance. [bjango: Designing macOS menu bar extras](https://bjango.com/articles/designingmenubarextras/)

### Keyboard and accessibility

5. **Esc-key handling already implemented; MenuBarExtra offers no equivalent — [already implemented, keep]** — Herdling installs a local key monitor while the panel is open (`installKeyMonitor` in `StatusItemController.swift`), Esc closes the panel or returns from settings, guarded against text fields. A window-style MenuBarExtra gives no comparable key-handling API, another reason not to migrate. Minor note: the monitor checks `panel.firstResponder is NSText`; if future controls add custom text input (e.g. search field), also check `NSResponder` subclasses like `NSTextView`/`NSSearchField` — fine today.

6. **Accessibility labels and tooltips already set; verify with VoiceOver — [already implemented; one verification task]** — The status button sets `toolTip`, `setAccessibilityLabel`, and the image's `accessibilityDescription` on every update (`MenuBarStatusItem.swift`); roster rows set `accessibilityLabel`, hide decorative glyphs with `accessibilityHidden`, and use real `Button`s with `.plain` style (keyboard-activatable). This matches modern AppKit/SwiftUI a11y practice. [WWDC25: Make your Mac app more accessible to everyone](https://developer.apple.com/videos/play/wwdc2025/229/) · [NSStatusItem docs](https://developer.apple.com/documentation/appkit/nsstatusitem) · [Setting accessibility title on status button](https://stackoverflow.com/questions/35729889/os-x-nsstatusitem-how-to-set-the-accessibility-title-for-voiceover) Verification task: run a VoiceOver pass over the panel (focus order, Esc/return behavior) — no code change flagged.

### Appearance

7. **Template rendering + adaptive colors already implemented — [already implemented]** — Status icon drawn as template image (auto-adapts to light/dark menu bar and accent tint) via `ImageRenderer`; panel colors adapt per appearance through `NSColor(name:)` (`StatusPalette` in `AgentListView.swift`). Correct pattern; keep. Minor: `summaryImage` re-renders every status change — cacheable by `MenuStatus` (it is `Equatable`); see finding 12.

### Lifecycle and activation

8. **Accessory activation + relaunch behavior already implemented — [already implemented]** — `setActivationPolicy(.accessory)` (no Dock icon, no Cmd-Tab entry) is the programmatic equivalent of `LSUIElement`; `disableRelaunchOnLogin()` prevents surprise relaunch into login items. [Apple LSUIElement docs](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) · [Launch Services keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html) Panel uses `.nonactivatingPanel` + `.popUpMenu` level + `[.canJoinAllSpaces, .fullScreenAuxiliary]` — standard for menu bar panels. [Fazm: floating panel patterns](https://fazm.ai/blog/swiftui-floating-panel)

### Launch at login

9. **SMAppService-based Launch at Login already implemented correctly — [already implemented; gated on packaging]** — `SMAppService.mainApp.register()/unregister()` with live `status` read, and `.requiresApproval` / `.notFound` surfaced as settings errors (`SessionStore.swift`). This is the modern macOS 13+ API replacing SMJobBless/SMLoginItemSetEnabled; explicit opt-in setting defaulting off is App Store-review-safe. [Apple SMAppService docs](https://developer.apple.com/documentation/servicemanagement/smappservice) · [theevilbit: SMAppService](https://theevilbit.github.io/posts/smappservice/) · [nilcoalescing: launch-at-login setting](https://nilcoalescing.com/blog/LaunchAtLoginSetting) Caveat: `.notFound` fires whenever Herdling runs from an SPM executable (no .app bundle) — correct today, but this is the strongest argument for packaging (finding 11).

### Polling, background work, performance — the biggest opportunities

10. **HIGH VALUE — Replace poll-and-spawn refresh with herdr's socket event stream — [implemented]** — `HerdrLocalSessionMonitor` keeps one NDJSON subscription per local Herdr session socket, bootstraps with `session.snapshot`, coalesces resource events into fresh snapshots, and publishes complete ordered session sets to `SessionStore`. Local CLI polling remains the fail-closed fallback when sockets disappear; SSH Sources continue polling. [herdr Socket API](https://herdr.dev/docs/socket-api/) This removes continuous local process spawning and aligns with Apple's energy guidance. [Apple Energy Efficiency Guide: Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html) · [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)

11. **MEDIUM — Exponential backoff on source failure — [implemented]** — `SourceRetryPolicy` skips failed SSH Sources for 15s, 30s, then 60s, resets on success, and preserves the existing one immediate initialization retry. Apple's guidance explicitly favors deferred background work over fixed retries. [Apple: Schedule Background Activity](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/SchedulingBackgroundActivity.html)

12. **LOW — Do not add an icon cache yet; remove CommandRunner polling only if it survives the socket migration — [defer]** — `StatusItemController` already compares `MenuStatus` with `lastStatus`, so `ImageRenderer` runs only for a changed summary. A second cache would add state for negligible gain and could grow with arbitrary count combinations. `CommandRunner.run` does busy-wait with `Thread.sleep(0.05)` on a worker thread; an async Process implementation would remove that spin, but replacing local CLI polling with the socket stream removes far more process work. Optimize the larger seam first. Already good: `GitBranchResolver` 15s cache, `LatestRequestRunner` focus coalescing, concurrent Source loading, and 2s/15s panel-aware polling.

### Update and distribution

13. **MEDIUM — Local app bundling exists; production distribution does not — [applicable; gap]** — `scripts/build-app.sh` creates `.build/Herdling.app`, copies resources, and applies an ad-hoc signature, so Herdling is not merely a raw SPM executable and local Launch at Login can be tested from a bundle. What is missing is a distributable artifact: Developer ID signature, Hardened Runtime/entitlements, notarization + stapling, versioned ZIP/DMG, and an update channel. Best practice outside the App Store is Developer ID signing + notarization, then optionally Sparkle 2 (HTTPS appcast, EdDSA signatures, binary deltas). [Sparkle documentation](https://sparkle-project.org/documentation) · [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [Steinberger: Code Signing and Notarization, Sparkle and Tears](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears) Decide distribution before adding Sparkle; do not introduce the dependency while the app is still local-only.

### Settings pattern

14. **In-panel settings already the pragmatic right choice — [already implemented; do not copy Settings scene]** — SwiftUI `Settings` scene + `SettingsLink` is unreliable from menu bar apps: "SettingsLink should open the app's settings scene… assumptions that don't hold for menu bar apps"; one author spent 5 hours working around it, and the `openSettings` environment action works on macOS 15 but not 14. [Zach Armstead: Showing Settings from macOS Menu Bar Items](https://zacharmstead.com/posts/2025/showing-settings-from-macos-menu-bar-items/) · [Michael Tsai: Showing Settings From macOS Menu Bar Items](https://mjtsai.com/blog/2025/06/18/showing-settings-from-macos-menu-bar-items/) Herdling's in-panel settings view (chevron back, grouped sections, `SettingsLink`-free) sidesteps this entirely. [Apple Settings scene docs](https://developer.apple.com/documentation/swiftui/settings)

### Small native-macOS gaps found in Herdling

15. **MEDIUM — Add app-level Cmd+, and Cmd+Q routing — [implemented]** — `HerdlingApplicationMenu` installs standard Settings and Quit items and routes Settings through the existing in-panel path. [Apple HIG: Keyboard](https://developer.apple.com/design/human-interface-guidelines/keyboards)

16. **MEDIUM — Add single-instance protection before enabling release distribution — [implemented]** — `SingleInstanceLock` uses a nonblocking kernel file lock. A second launch posts a distributed activation notification, exits, and asks the existing instance to show its panel. [OpenUsage App lifecycle source](https://github.com/robinebers/openusage/blob/main/Sources/OpenUsage/App/OpenUsageApp.swift)

17. **LOW — Render the status strip at the status button's actual backing scale — [implemented]** — `MenuBarStatusItem` reads the status button window's `backingScaleFactor` and falls back to the main screen. Keyboard-focus outlines and accessibility hints were also added to roster controls. [Apple NSScreen backingScaleFactor](https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor)

## Recommended order

1. Measure a 10-minute panel-open and panel-closed session with Instruments/Energy Log and count spawned `herdr`, `ssh`, and `git` processes. Keep the measurement as the baseline.
2. Prototype one local `HerdrSocketClient` module: bootstrap with `session.snapshot`, subscribe to workspace/tab/pane/agent lifecycle events, reconnect by taking a fresh snapshot, and retain the current polling adapter for SSH Sources and socket failure.
3. Add the small native lifecycle fixes: Cmd+,/Cmd+Q and single-instance protection.
4. Add per-Source failure backoff if failed SSH Sources still dominate wakeups after local socket adoption.
5. Decide the release channel, then add Developer ID signing/notarization and only then evaluate Sparkle.

Do **not** migrate to `MenuBarExtra`, `NSPopover`, or a SwiftUI `Settings` scene; do **not** add a status-image cache before profiling.

## Sources

- Kept: [Apple HIG: The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) — primary design authority; menu-vs-popover guidance.
- Kept: [Apple MenuBarExtra docs](https://developer.apple.com/documentation/swiftui/menubarextra) — primary API reference for scene + styles.
- Kept: [Apple NSPopover docs](https://developer.apple.com/documentation/appkit/nspopover) — transient/semi-transient behavior authority.
- Kept: [Apple SMAppService docs](https://developer.apple.com/documentation/servicemanagement/smappservice) — login-item API authority.
- Kept: [Apple Energy Efficiency Guide (Best Practices / Timers / Background Activity)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/) — primary guidance backing polling findings.
- Kept: [Apple LSUIElement docs](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) — agent-app behavior authority.
- Kept: [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — distribution requirement authority.
- Kept: [herdr Socket API](https://herdr.dev/docs/socket-api/) — first-party stream API enabling push architecture.
- Kept: [Sparkle documentation](https://sparkle-project.org/documentation) — first-party updater docs (signing, notarization interplay).
- Kept: [runner-bar #377](https://github.com/eoncode/runner-bar/issues/377) — maintainer-verified NSPopover re-anchor defect.
- Kept: [Irrlicht #189](https://github.com/ingo-eichhorst/Irrlicht/issues/189) — maintainer migration MenuBarExtra→NSPanel, resize-race evidence.
- Kept: [orchetect/MenuBarExtraAccess #14](https://github.com/orchetect/MenuBarExtraAccess/issues/14) — isMenuPresented inversion defect.
- Kept: [bjango: Designing macOS menu bar extras](https://bjango.com/articles/designingmenubarextras/) — icon sizing/geometry guidance.
- Kept: [Zach Armstead: Settings from menu bar items](https://zacharmstead.com/posts/2025/showing-settings-from-macos-menu-bar-items/) + [Michael Tsai](https://mjtsai.com/blog/2025/06/18/showing-settings-from-macos-menu-bar-items/) — Settings scene unreliability from menu bar apps.
- Kept: [FluidMenuBarExtra](https://github.com/wadetregaskis/FluidMenuBarExtra) — evidence MenuBarExtra needs third-party fixups.
- Kept: [nilcoalescing: launch-at-login setting](https://nilcoalescing.com/blog/LaunchAtLoginSetting) — default-off opt-in practice.
- Kept: [theevilbit: SMAppService](https://theevilbit.github.io/posts/smappservice/) — API migration context.
- Kept: [Barkeep: menu bar app gotchas](https://barkeepmac.com/build-macos-menu-bar-app-swift.html) — strong-ref status item, notch, permission survival.
- Kept: [WWDC25: Make your Mac app more accessible](https://developer.apple.com/videos/play/wwdc2025/229/) — a11y verification baseline.
- Dropped: `developerguidelines.com` HIG mirror, `apple-docs.everest.mt` mirrors, `yourstash.ai`/`techconcepts.org` guides — redundant with primary sources.
- Dropped: reddit/osxdaily App Nap toggles — user workarounds, not engineering practice.

## Gaps

- Could not verify against a live run: actual CPU/energy profile of the 2s/15s poll loop. The documented socket is local; remote SSH Sources should retain a polling adapter unless Herdr later exposes a supported remote stream.
- macOS 26 status-item removal/user-hiding APIs not verified; HIG "let people decide" item left as principle only.
- Notarization/Sparkle steps not executed — concrete pipeline (Xcode project vs SPM bundling, entitlements) needs a decision on packaging approach.
- Remaining next steps: (1) decide production packaging/notarization/updater path; (2) run VoiceOver acceptance on every supported macOS release; (3) profile energy use after extended local/SSH operation.
