import AppKit
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct SettingsWindowTests {
    @Test
    func settingsCentersInitiallyAndRestoresSavedGeometry() throws {
        _ = NSApplication.shared
        let name = "HerdlingSettingsTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let store = PreviewFixtures.makeStore()
        let first = SettingsWindowController(store: store, frameAutosaveName: name)
        let firstWindow = try #require(first.window)
        defer { firstWindow.close() }
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let initialFrame = firstWindow.frame
        firstWindow.center()
        #expect(firstWindow.frame == initialFrame, "An unsaved window must already be centered")
        firstWindow.setFrame(NSRect(
            x: firstWindow.frame.minX + 24, y: firstWindow.frame.minY - 24,
            width: firstWindow.frame.width + 80, height: firstWindow.frame.height + 60
        ), display: false)
        let savedFrame = firstWindow.frame
        firstWindow.saveFrame(usingName: name)
        firstWindow.setFrameAutosaveName("")

        let reopened = SettingsWindowController(store: store, frameAutosaveName: name)
        let window = try #require(reopened.window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.setFrameAutosaveName("")
        #expect(window.frame == savedFrame)
        #expect(!window.isVisible)
    }

    @Test
    func closeUsesTheStandardResponderChainShortcut() throws {
        _ = NSApplication.shared
        let menu = HerdlingApplicationMenu.make(settingsTarget: NSObject())
        let fileMenu = try #require(menu.items.first { $0.submenu?.title == "File" }?.submenu)

        let window = SettingsCloseProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let previousResponder = NSApp.nextResponder
        let previousMenu = NSApp.mainMenu
        defer {
            NSApp.nextResponder = previousResponder
            NSApp.mainMenu = previousMenu
        }
        // A controlled responder chain exercises native dispatch without making a window key.
        NSApp.nextResponder = window
        NSApp.mainMenu = menu
        fileMenu.update()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(window.closeCount == 1)
        #expect(!window.isVisible)
    }
}

@MainActor
private final class SettingsCloseProbeWindow: NSWindow {
    var closeCount = 0

    override func close() {
        closeCount += 1
        super.close()
    }
}
