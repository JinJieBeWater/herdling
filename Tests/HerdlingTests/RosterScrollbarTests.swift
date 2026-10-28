import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct RosterScrollbarTests {
    @Test
    func wheelAndKeyboardSelectionScrollWithoutNavigating() throws {
        let screen = try #require(NSScreen.screens.first)
        let store = PreviewFixtures.makeStore()
        let agents = (0..<30).map { index in
            AgentInfo(paneID: "scroll-pane-\(index)", title: "Agent \(index)", status: .working,
                      workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        }
        let source = SourceInfo(descriptor: .local,
            sessions: [SessionInfo(name: "default", agents: agents, online: true)], online: true)
        let browser = NavigationBrowser(sources: [source])
        let view = NSHostingView(rootView: AgentListView(store: store, browser: browser))
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 240)
        // SwiftUI wheel handling needs a screen association; keep the fixture invisible and unfocused.
        let window = NSWindow(contentRect: NSRect(origin: screen.visibleFrame.origin, size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        settle(view)

        let scroll = try #require(findScrollView(view))
        let scroller = try #require(scroll.verticalScroller)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: -100, wheel2: 0, wheel3: 0))
        scroller.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        settle(view)
        #expect(scroll.contentView.bounds.minY > 0)

        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        browser.moveSelection(by: 1)
        settle(view)
        #expect(scroll.contentView.bounds.minY < 50, "Keyboard selection must bring the first target back into view")
        #expect(store.navigationAttempt == nil, "Scrolling must not open a terminal")
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        view.layoutSubtreeIfNeeded()
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { findScrollView($0) }.first
    }
}
