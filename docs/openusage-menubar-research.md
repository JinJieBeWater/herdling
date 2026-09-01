# OpenUsage menu-bar patterns for Herdling

Checked against [`robinebers/openusage`](https://github.com/robinebers/openusage) at commit `05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61` on 2026-08-30.

## Findings

OpenUsage uses `NSStatusItem` plus a key-capable borderless `NSPanel`, not `MenuBarExtra` or `NSPopover`. Herdling already uses the same core seam. The relevant upstream files are:

- [`StatusItemController.swift`](https://github.com/robinebers/openusage/blob/05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61/Sources/OpenUsage/App/StatusItemController.swift)
- [`StatusItemImageUpdater.swift`](https://github.com/robinebers/openusage/blob/05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61/Sources/OpenUsage/App/StatusItemImageUpdater.swift)
- [`PanelOutsideClickMonitor.swift`](https://github.com/robinebers/openusage/blob/05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61/Sources/OpenUsage/App/PanelOutsideClickMonitor.swift)
- [`MenuBarStripRenderer.swift`](https://github.com/robinebers/openusage/blob/05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61/Sources/OpenUsage/Support/MenuBarStripRenderer.swift)
- [`PopoverDismissReader.swift`](https://github.com/robinebers/openusage/blob/05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61/Sources/OpenUsage/Support/PopoverDismissReader.swift)

### Icon

OpenUsage renders black-on-transparent artwork into an `NSImage`, sets `isTemplate = true`, and never sets `contentTintColor`. macOS supplies light, dark, and pressed colors. Text is baked into the image instead of assigned through `button.title`. Every image carries an accessibility description.

Herdling's fixed red, green, blue, and secondary `contentTintColor` values bypass this adaptation and caused the dark/black appearance. Herdling should use one template symbol plus short template text/count treatment and communicate state through symbol shape, not fixed color.

### Click behavior

OpenUsage routes `.leftMouseUp` and `.rightMouseUp` through one action:

- left click toggles the panel;
- right click or control-click closes the panel and opens a native Settings/Quit menu;
- the native menu is shown by temporarily assigning `statusItem.menu`, calling `button.performClick(nil)`, then clearing the menu.

### Open/close behavior

Panel open and close explicitly call `button.highlight(true/false)`. Panel level is `.popUpMenu`; it does not hide on app deactivation and joins all spaces/full-screen auxiliary spaces.

Outside-click handling uses both local and global mouse-down monitors. Clicks stay open when they hit the panel or status button. Status-button hit testing extends to the top of the screen with inclusive edges; otherwise mouse-down closes the panel before the button's mouse-up toggles it open again.

Esc is accepted only while the panel is visible and owns the key event. Text editing keeps the key.

### Placement

OpenUsage left-aligns the panel below the status item and clamps it inside the current screen's `visibleFrame` with an 8-point margin. Herdling's centered, unclamped frame can leave the screen near menu-bar edges.

### Update cost

OpenUsage memoizes rendered images and skips assigning the same `NSImage` instance. Its observation callback debounces refresh bursts by 50 ms. Herdling's state is much smaller, so status-value memoization is sufficient now; add render debounce only if measured refresh churn appears.

## Herdling decisions

Adopt:

1. Template-only status image; no `contentTintColor`.
2. State-specific SF Symbol shape and compact count.
3. Manual pressed highlight while panel is visible.
4. Left toggle and right/control-click Settings/Quit menu.
5. Local and global outside-click monitoring that ignores panel/status-button clicks.
6. Key-window-gated Esc.
7. Screen-clamped panel placement and `.popUpMenu` layering.
8. Skip redundant image assignment when status is unchanged.

Do not copy:

- dynamic metric-strip renderer, transparency system, animated panel height, global shortcut, or provider layout;
- `StatusItemImageUpdater` as a separate module until Herdling has enough rendering work to justify that seam.
