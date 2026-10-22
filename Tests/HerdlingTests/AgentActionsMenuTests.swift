import AppKit
import Testing
@testable import Herdling

@Suite(.serialized) @MainActor
struct AgentActionsMenuTests {
    @Test func clicksInAnOwnedChildOutsideTheRosterDoNotDismissTheRoster() throws {
        let parent = MenuBarPanel(), child = MenuBarPanel()
        let screen = try #require(NSScreen.main).visibleFrame
        let pointer = NSEvent.mouseLocation
        let x = pointer.x < screen.midX ? screen.maxX - 440 : screen.minX + 20
        parent.setFrame(NSRect(x: x, y: screen.midY - 50, width: 420, height: 100), display: false)
        child.setFrame(NSRect(x: x + 87, y: parent.frame.maxY, width: 320, height: 120), display: false)
        parent.orderFront(nil)
        parent.addChildWindow(child, ordered: .above)
        child.orderFront(nil)
        var dismissed = false
        let monitor = PanelOutsideClickMonitor(panel: parent, statusItems: [], onDismiss: { dismissed = true })
        monitor.start()
        defer { monitor.stop(); parent.removeChildWindow(child); child.orderOut(nil); parent.orderOut(nil) }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: child.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
        #expect(!dismissed)
        #expect(parent.isVisible)
    }

    @Test func secondaryActionSelectsTheTargetWithoutNavigatingOrResizingTheRoster() throws {
        let store = PreviewFixtures.makeStore()
        let agent = AgentInfo(paneID: "fixture", title: "Menu fixture", status: .working,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, keyboard: false, expandedSourceID: nil)
        let destination = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "fixture")
        let parent = MenuBarPanel()
        let screen = try #require(NSScreen.main).visibleFrame
        parent.setFrame(NSRect(x: screen.midX - 210, y: screen.midY - 150, width: 420, height: 300), display: false)
        parent.orderFront(nil)
        let before = parent.frame
        let menu = AgentActionsMenuController(parent: parent, store: store, browser: browser)
        defer { menu.dismiss(returnFocus: false); parent.orderOut(nil) }

        menu.present(for: destination)
        let child = try #require(parent.childWindows?.first)
        #expect(child.frame.size == NSSize(width: 208, height: 68), "Two supplementary commands must not occupy a launcher-sized palette")
        #expect(child.isVisible && menu.isPresented)
        #expect(child.frame.maxX == before.maxX - 13 && child.frame.minY == before.minY + 13)
        #expect(parent.frame == before)
        #expect(browser.selection == .destination(destination))
        #expect(store.navigationAttempt == nil)
        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: child.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        #expect(menu.handleKeyDown(try key(125))) // Choose the supplementary action, not Open.
        #expect(menu.handleKeyDown(try key(36)))
        #expect(store.isObserveOnly(destination))
        #expect(!menu.isPresented && parent.isVisible)
        #expect(parent.childWindows?.isEmpty != false)
        #expect(parent.frame == before && store.navigationAttempt == nil)
    }
}
