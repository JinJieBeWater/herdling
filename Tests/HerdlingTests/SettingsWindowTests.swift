import AppKit
import Observation
import ServiceManagement
import Synchronization
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct SettingsWindowTests {
    @Test(.timeLimit(.minutes(1)))
    func refocusingRefreshesSystemStatusWithoutRegisteringOrClearingOperationErrors() async throws {
        _ = NSApplication.shared
        var loginStatus = SMAppService.Status.requiresApproval
        var registrationCalls = 0
        let terminalStatus = Mutex("Denied")
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadTerminalStatus: { _ in terminalStatus.withLock { $0 } },
            loadLoginItemStatus: { loginStatus },
            updateLoginItem: { _ in
                registrationCalls += 1
                throw NSError(domain: "SettingsTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot update login item"])
            },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults()
        )
        let name = "HerdlingSettingsTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let controller = SettingsWindowController(
            store: store, updaterSettings: UpdaterSettings(updater: makeInactiveUpdaterController().updater),
            frameAutosaveName: name
        )
        let window = try #require(controller.window)
        defer { window.setFrameAutosaveName(""); window.close() }
        let delegate = try #require(window.delegate as? SettingsWindowController)
        let updates = AsyncStream<Void>.makeStream()
        defer { updates.continuation.finish() }
        func refocus() async throws {
            var notifications = updates.stream.makeAsyncIterator()
            withObservationTracking { _ = store.terminalStatus } onChange: {
                updates.continuation.yield(())
            }
            // Exercise the wired delegate without activating a window on the user's desktop.
            delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            try #require(await notifications.next() != nil)
        }

        try await refocus()
        #expect(!store.launchAtLoginEnabled)
        #expect(store.settingsError?.contains("requires approval") == true)
        #expect(store.terminalStatus == "Denied")

        loginStatus = .enabled
        terminalStatus.withLock { $0 = "Allowed" }
        try await refocus()
        #expect(store.launchAtLoginEnabled)
        #expect(store.settingsError == nil)
        #expect(store.terminalStatus == "Allowed")
        #expect(registrationCalls == 0)

        store.setLaunchAtLogin(false)
        terminalStatus.withLock { $0 = "Denied" }
        try await refocus()
        #expect(store.launchAtLoginEnabled)
        #expect(store.settingsError == "Cannot update login item")
        #expect(registrationCalls == 1)
        #expect(!window.isVisible)
    }

    @Test
    func settingsCentersInitiallyAndRestoresSavedGeometry() throws {
        _ = NSApplication.shared
        let name = "HerdlingSettingsTests.\(UUID())"
        defer { NSWindow.removeFrame(usingName: name) }
        let store = PreviewFixtures.makeStore()
        let updaterSettings = UpdaterSettings(updater: makeInactiveUpdaterController().updater)
        let first = SettingsWindowController(store: store, updaterSettings: updaterSettings, frameAutosaveName: name)
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

        let reopened = SettingsWindowController(store: store, updaterSettings: updaterSettings, frameAutosaveName: name)
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
        let menu = HerdlingApplicationMenu.make(settingsTarget: NSObject(), updaterController: makeInactiveUpdaterController())
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
