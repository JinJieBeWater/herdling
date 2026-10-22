import AppKit
import SwiftUI
import Testing
@testable import Herdling

/// The panel's own measurements, taken with real AppKit geometry.
///
/// Checks row roles, expanded spacing budgets and complete panel height through rendered layout.
///
/// Visible shell clearance belongs to PanelChromeTests and native panel captures; these checks
/// cover layout budgets and complete window height.
@Suite
@MainActor
struct PanelLayoutTests {
    @Test func agentActionMenuUsesThePanelCornerAndFitsShortPanelsWithoutResizingThem() {
        let parent = NSRect(x: 100, y: 100, width: 420, height: 300)
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(AgentActionsMenuController.frame(parent: parent, contentSize: NSSize(width: 320, height: 140), visibleFrame: screen)
                == NSRect(x: 187, y: 113, width: 320, height: 140))
        let short = NSRect(x: 100, y: 870, width: 420, height: 100)
        let fitted = AgentActionsMenuController.frame(parent: short, contentSize: NSSize(width: 320, height: 140), visibleFrame: screen)
        #expect(fitted.maxX == 507)
        #expect(fitted.maxY <= 987 && fitted.minY >= 13)
        #expect(fitted.height == 140, "Menu owns its height even when taller than the roster")
    }

    @Test
    func allPanelAllowsItsEmptySessionDirectoryToCollapseAndExpand() {
        let store = PreviewFixtures.makeStore()
        let browser = NavigationBrowser(sources: [
            SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", groups: [], online: true)], online: true),
            SourceInfo(descriptor: .remote("kvm"), sessions: [], online: false, error: "Offline")
        ])
        browser.setMode(.all)
        for expanded in [false, true] {
            if expanded { browser.toggleSource("local") }
            let measurement = CapturedPanelHeight()
            _ = fittingHeight {
                AgentListView(store: store, browser: browser)
                    .onPreferenceChange(PanelContentHeightKey.self) { value in
                        MainActor.assumeIsolated { measurement.height = value }
                    }
            }
            // 38pt controls + 4pt header/list gap + two 38pt sources + 4pt source gap + 21pt insets,
            // plus the expanded directory's 4pt clearance and 32pt default-session Open action.
            #expect(measurement.height == (expanded ? 179 : 143))
        }
    }

    @Test
    func expandedRosterIncludesRowAndGroupGapsWithoutExtraSectionTail() async {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        for expanded in [false, true] {
            let browser = NavigationBrowser(sources: store.sources)
            browser.setMode(.all)
            if expanded { browser.toggleSource(SourceDescriptor.local.id) }
            let measurement = CapturedPanelHeight()
            _ = fittingHeight {
                AgentListView(store: store, browser: browser)
                    .onPreferenceChange(PanelContentHeightKey.self) { value in
                        MainActor.assumeIsolated { measurement.height = value }
                    }
            }
            // Fixed controls, 4pt header/list gap, two source headers, 4pt source gap and insets = 143.
            // Expanded fixture adds 4pt + eleven 32pt rows + eight 2pt row gaps
            // + two 8pt group gaps = 388. No extra padding after the last agent.
            #expect(measurement.height == (expanded ? 531 : 143))
        }
    }

    @Test
    func contentRowsStayCompactWhileSectionHeadersRemainProminent() {
        let row = fittingHeight {
            HoverRow(accessibilityText: "row", action: {}) { _ in
                RowSymbol(symbol: "desktopcomputer", tint: Theme.Hue.blue)
                Text("Title")
            }
        }
        #expect(row == 32)

        let header = fittingHeight {
            GroupHeaderRow(
                leading: RowSymbol(symbol: "desktopcomputer", tint: Theme.Hue.blue),
                title: "Header", isExpanded: true,
                accessibilityLabel: "header", accessibilityHint: "Toggle", action: {}
            ) { EmptyView() }
        }
        #expect(header == 38)
    }

    /// Ordinary row fills stay more compact than the outer surface and do not become capsules.
    @Test
    func contentRadiiStayBelowTheirRows() {
        #expect(Theme.Radius.row * 2 < Theme.Size.rowMinHeight)
        #expect(Theme.Radius.row < Theme.Radius.panel)
    }

    private func fittingHeight(@ViewBuilder _ view: () -> some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view())
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: 200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<2 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.current.run(until: Date().addingTimeInterval(Theme.Duration.expand * 2))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}

@MainActor
private final class CapturedPanelHeight {
    var height: CGFloat = 0
}
