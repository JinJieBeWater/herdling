import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct TerminalSelectionTests {
    @Test
    func settingsOffersBothTerminals() throws {
        let store = PreviewFixtures.makeStore()
        let hosting = NSHostingView(rootView: SettingsView(store: store))
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.settingsWidth, height: Theme.Size.settingsHeight)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        func controls(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let picker = try #require(controls(in: hosting).first { control in
            Set((0..<control.segmentCount).compactMap { control.label(forSegment: $0) }) == ["Ghostty", "Kero"]
        }, "Settings must let the user choose Ghostty or Kero")
        #expect(picker.isEnabled)
        store.setGhosttyOpenBehavior(.window)
        let keroIndex = try #require((0..<picker.segmentCount).first { picker.label(forSegment: $0) == "Kero" })
        picker.selectedSegment = keroIndex
        #expect(picker.sendAction(picker.action, to: picker.target))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        #expect(store.terminalApplication == .kero)
        #expect(!controls(in: hosting).contains { control in
            Set((0..<control.segmentCount).compactMap { control.label(forSegment: $0) }) == ["Window", "Tab"]
        }, "Ghostty's window/tab control must not appear for Kero")
        let ghosttyIndex = try #require((0..<picker.segmentCount).first { picker.label(forSegment: $0) == "Ghostty" })
        picker.selectedSegment = ghosttyIndex
        #expect(picker.sendAction(picker.action, to: picker.target))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        #expect(store.terminalApplication == .ghostty)
        let behavior = try #require(controls(in: hosting).first { control in
            Set((0..<control.segmentCount).compactMap { control.label(forSegment: $0) }) == ["Window", "Tab"]
        })
        #expect(behavior.label(forSegment: behavior.selectedSegment) == "Window")
        #expect(store.navigationAttempt == nil, "Changing terminal preferences must not navigate")
    }

    @Test
    func choicePersistsAndKeepsExistingGhosttyPreferences() {
        let defaults = PreviewFixtures.renderDefaults()
        defaults.set("window", forKey: "ghostty-open-behavior")
        let store = PreviewFixtures.makeStore(defaults: defaults)
        #expect(store.terminalApplication == .ghostty)
        #expect(store.ghosttyOpenBehavior == .window)
        store.setTerminalApplication(.kero)
        #expect(defaults.string(forKey: "terminal-application") == "kero")
        let reopened = PreviewFixtures.makeStore(defaults: defaults)
        #expect(reopened.terminalApplication == .kero)
        reopened.setTerminalApplication(.ghostty)
        #expect(reopened.ghosttyOpenBehavior == .window)
        #expect(defaults.string(forKey: "terminal-application") == "ghostty")
        #expect(reopened.navigationAttempt == nil)
    }

    @Test
    func invalidPreferenceDoesNotSilentlySwitchExistingUsersToKero() {
        let defaults = PreviewFixtures.renderDefaults()
        defaults.set("removed-terminal", forKey: "terminal-application")
        #expect(PreviewFixtures.makeStore(defaults: defaults).terminalApplication == .ghostty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: TerminalApplication.allCases)
    func selectedTerminalReceivesBothLocalAndRemoteReuseOrCreation(application: TerminalApplication) async throws {
        for reuse in [false, true] {
            for source in [SourceDescriptor.local, .remote("kvm")] {
                let events = TerminalEvents()
                let client = HerdrClient(executable: "/fake/herdr")
                let expectedCommand = try client.attachCommand(source: source, session: "work")
                let store = SessionStore(
                    client: client,
                    loadSource: { _ in [.init(name: "work", groups: [], error: nil)] },
                    loadBranches: { _, _ in [:] },
                    focusExistingClient: { actualSource, name, terminal in
                        #expect(actualSource == source && name == "work" && terminal == application)
                        _ = await events.record("reuse")
                        return reuse
                    },
                    sourceDescriptors: [source], defaults: PreviewFixtures.renderDefaults(),
                    activateClient: { actualSource, name, command, terminal, behavior in
                        #expect(actualSource == source && name == "work" && terminal == application)
                        #expect(behavior == .window)
                        #expect(command == expectedCommand)
                        _ = await events.record("create")
                    }
                )
                store.setTerminalApplication(application)
                store.setGhosttyOpenBehavior(.window)
                await store.refresh()
                store.navigate(to: .session(sourceID: source.id, sessionName: "work"))
                await waitForNavigation(store)
                #expect(store.navigationAttempt?.phase == .succeeded)
                #expect(await events.values == (reuse ? ["reuse"] : ["reuse", "create"]))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func changingPreferencesMidJumpOnlyAffectsTheNextJump() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); release.continuation.finish() }
        let events = TerminalEvents()
        let store = SessionStore(
            client: HerdrClient(executable: "/fake/herdr"),
            loadSource: { _ in [.init(name: "work", groups: [], error: nil)] },
            loadBranches: { _, _ in [:] },
            focusExistingClient: { _, _, terminal in
                _ = await events.record("reuse-\(terminal.rawValue)")
                started.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return false
            },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(),
            activateClient: { _, _, _, terminal, behavior in
                _ = await events.record("create-\(terminal.rawValue)-\(behavior.rawValue)")
            }
        )
        store.setGhosttyOpenBehavior(.window)
        await store.refresh()
        let destination = NavigationDestination.session(sourceID: "local", sessionName: "work")
        store.navigate(to: destination)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        store.setTerminalApplication(.kero)
        store.setGhosttyOpenBehavior(.tab)
        release.continuation.finish()
        await waitForNavigation(store)
        #expect(await events.values == ["reuse-ghostty", "create-ghostty-window"])
        store.navigate(to: destination)
        await waitForNavigation(store)
        #expect(await events.values == ["reuse-ghostty", "create-ghostty-window", "reuse-kero", "create-kero-tab"])
        #expect(store.navigationAttempt?.phase == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleStatusCannotReplaceTheNewSelectionEvenAfterSwitchingBack() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { started.continuation.finish(); release.continuation.finish() }
        let events = TerminalEvents()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadTerminalStatus: { terminal in
                let request = await events.record(terminal.rawValue)
                if request == 1 {
                    started.continuation.yield(())
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                }
                return "status-\(request)"
            },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults()
        )
        let first = Task { await store.refreshTerminalStatus() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        store.setTerminalApplication(.kero)
        #expect(store.terminalStatus == "Not checked")
        await store.refreshTerminalStatus()
        #expect(store.terminalStatus == "status-2")
        store.setTerminalApplication(.ghostty)
        await store.refreshTerminalStatus()
        release.continuation.finish()
        await first.value
        #expect(store.terminalStatus == "status-3")
        #expect(await events.values == ["ghostty", "kero", "ghostty"])
    }

    private func waitForNavigation(_ store: SessionStore) async {
        while store.navigationAttempt?.phase == .pending, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor TerminalEvents {
    private(set) var values: [String] = []
    func record(_ value: String) -> Int {
        values.append(value)
        return values.count
    }
}
