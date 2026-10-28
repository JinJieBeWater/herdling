import Foundation
import Testing
@testable import Herdling

@MainActor
struct TerminalSelectionTests {
    @Test
    func choicePersistsAndKeepsExistingGhosttyPreferences() {
        let defaults = PreviewFixtures.renderDefaults()
        let store = PreviewFixtures.makeStore(defaults: defaults)
        #expect(store.terminalApplication == .ghostty)
        #expect(store.ghosttyOpenBehavior == .tab)
        store.setGhosttyOpenBehavior(.window)
        store.setTerminalApplication(.kero)
        #expect(defaults.string(forKey: "terminal-application") == "kero")
        let reopened = PreviewFixtures.makeStore(defaults: defaults)
        #expect(reopened.terminalApplication == .kero)
        reopened.setTerminalApplication(.ghostty)
        #expect(reopened.ghosttyOpenBehavior == .window)
        #expect(defaults.string(forKey: "terminal-application") == "ghostty")
        #expect(reopened.navigationAttempt == nil)
        defaults.set("removed-terminal", forKey: "terminal-application")
        #expect(PreviewFixtures.makeStore(defaults: defaults).terminalApplication == .ghostty)
    }

    @Test(.timeLimit(.minutes(1)))
    func selectedTerminalReceivesRemoteCreationThenReuse() async throws {
        let source = SourceDescriptor.remote("kvm")
        let events = TerminalEvents()
        let client = HerdrClient(executable: "/fake/herdr")
        let expectedCommand = try client.attachCommand(source: source, session: "work")
        let store = SessionStore(
            client: client,
            loadSource: { _ in [.init(name: "work", groups: [], error: nil)] },
            loadBranches: { _, _ in [:] },
            focusExistingClient: { actualSource, name, terminal in
                #expect(actualSource == source && name == "work" && terminal == .kero)
                return await events.record("reuse") > 1
            },
            sourceDescriptors: [source], defaults: PreviewFixtures.renderDefaults(),
            activateClient: { actualSource, name, command, terminal, _ in
                #expect(actualSource == source && name == "work" && terminal == .kero)
                #expect(command == expectedCommand)
                _ = await events.record("create")
            }
        )
        store.setTerminalApplication(.kero)
        await store.refresh()
        let destination = NavigationDestination.session(sourceID: source.id, sessionName: "work")
        store.navigate(to: destination)
        await waitForNavigation(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        store.navigate(to: destination)
        await waitForNavigation(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(await events.values == ["reuse", "create", "reuse"])
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
