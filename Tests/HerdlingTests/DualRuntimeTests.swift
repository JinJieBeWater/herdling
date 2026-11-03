import Foundation
import Testing
@testable import Herdling

@MainActor
struct DualRuntimeTests {
    @Test
    func activitySharesPriorityAndThreeIdleBudgetWithoutMergingNativeIdentities() {
        let source = mixedSource()
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, expandedSourceID: "local")
        #expect(browser.quickIDs.prefix(3) == [legacy("t7"), .coreTerminal(coreID("t7")), legacy("working")])
        let idle = browser.quickIDs.filter { browser.presentation(for: $0).status == .idle }
        #expect(idle == [.coreTerminal(coreID("t1b")), .coreTerminal(coreID("t9z")), legacy("idle")])
        #expect(!browser.quickIDs.contains(.coreTerminal(coreID("t8"))))
        #expect(browser.quickIDs.contains(legacy("t7")))
        #expect(browser.quickIDs.contains(.coreTerminal(coreID("t7"))))
        #expect(MenuStatus.summarize([source]).counts.map(\.status) == [.blocked, .error, .working, .idle])
    }

    @Test
    func subAgentsFoldIntoTheirParentAsHerdrT3FocusReadsThem() {
        let rule = CoreTerminalInfo.treeStatus
        #expect(rule(.done, [.working, .done]) == .done)
        #expect(rule(.idle, [.working, .done]) == .working)
        #expect(rule(.working, [.error]) == .blocked)
        #expect(rule(.idle, [.done, .idle]) == .idle)
        #expect(rule(.done, [.done]) == .done)
        #expect(rule(.error, [.working]) == .error)
        #expect(rule(nil, [.blocked]) == nil)
    }

    @Test
    func parentRowCarriesItsWholeSubAgentTree() async {
        let monitor = DualCoreMonitor()
        let store = makeStore(monitor: monitor, app: appSnapshot(status: .done))
        await store.refresh()
        store.start()
        func parent(_ kids: [HerdrCoreTerminal]) async -> CoreTerminalInfo? {
            await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)] + kids)))
            return store.sources[0].core?.terminals.first { $0.id == coreID("t7") }
        }
        // Its unread reply shows first; the working sub-agent still shows beside it.
        let working = await parent([wireTerminal("t8", .working, parent: "t7"), wireTerminal("t9", .done, parent: "t7")])
        #expect(working?.status == .done)
        #expect(working?.workingSubAgents == 1)
        #expect(store.sources[0].core?.terminals.first { $0.id == coreID("t8") }?.status == nil)
        #expect(NavigationDestination.coreTerminal(coreID("t7")).resolve(in: store.sources)?.subtitle.hasSuffix("· 1 sub-agent working") == true)
        let stuck = await parent([wireTerminal("t8", .working, parent: "t7"), wireTerminal("t9", .error, parent: "t8")])
        #expect(stuck?.status == .blocked)
        let finished = await parent([wireTerminal("t8", .done, parent: "t7")])
        #expect(finished?.status == .done)
        #expect(finished?.workingSubAgents == 0)
        await store.stopAndWait()
    }

    @Test
    func coreTopologyFreezesButAvailabilityAndStatusStayLive() {
        var source = mixedSource()
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, expandedSourceID: "local")
        let original = browser.quickIDs
        source.core?.terminals = [coreInfo("new", .blocked, time: 100)]
        browser.receive(sources: [source], attempt: nil)
        #expect(browser.quickIDs == original)
        #expect(!browser.isAvailable(.coreTerminal(coreID("t7"))))
        #expect(browser.allSources[0].core?.terminals.contains { $0.id == coreID("new") } == false)
        browser.close()
        browser.open(sources: [source], attempt: nil, expandedSourceID: "local")
        #expect(browser.quickIDs.contains(.coreTerminal(coreID("new")) ))
    }

    @Test
    func oneRuntimeFailureDoesNotHideTheOtherOrCountStaleReports() {
        var source = mixedSource()
        source.online = false
        source.error = "Herdr offline"
        let browser = NavigationBrowser(sources: [source])
        #expect(browser.hasOnlineCoverage)
        #expect(browser.quickIDs.contains(.coreTerminal(coreID("t7"))))
        #expect(!browser.quickIDs.contains(legacy("t7")))
        #expect(MenuStatus.summarize([source]).availability == .online)
        source.online = true
        source.core?.online = false
        browser.receive(sources: [source], attempt: nil)
        #expect(browser.quickIDs.contains(legacy("t7")))
        #expect(!browser.quickIDs.contains(.coreTerminal(coreID("t7")) ))
        #expect(!MenuStatus.summarize([source]).counts.contains { $0.status == .error })
    }

    @Test
    func twoCoresWithTheSameShortAddressResolveIndependently() {
        let a = mixedSource()
        var b = SourceInfo(descriptor: .remote("other"), sessions: [], online: false, error: nil, hasLegacy: false)
        b.core = CoreSourceInfo(coreID: "other-core", terminals: [coreInfo("t7", .blocked, core: "other-core")],
                                online: true, error: nil, retryAt: nil)
        let first = NavigationDestination.coreTerminal(coreID("t7")).resolve(in: [a, b])
        let second = NavigationDestination.coreTerminal(coreID("t7", core: "other-core")).resolve(in: [a, b])
        #expect(first?.source.id == "local")
        #expect(second?.source.id == "ssh:other")
        #expect(first?.coreTerminal?.target.id != second?.coreTerminal?.target.id)
        #expect(first?.session == nil && second?.session == nil)
    }

    @Test
    func movingCorePresentationGroupDoesNotFreezeItsRuntimeState() {
        var original = mixedSource()
        let browser = NavigationBrowser()
        browser.open(sources: [original], attempt: nil, expandedSourceID: "local")
        let moved = SourceInfo(descriptor: .remote("renamed-route"), sessions: [], online: false,
                               error: nil, hasLegacy: false, core: original.core)
        original.core = nil
        browser.receive(sources: [original, moved], attempt: nil)
        #expect(browser.allSources.count == 1)
        #expect(browser.allSources[0].core?.online == true)
        #expect(browser.allSources[0].core?.terminals.first?.status == .error)
        #expect(browser.isAvailable(.coreTerminal(coreID("t7"))))
    }

    @Test
    func legacySSHChangesCannotRemoveCoreAndLateCoreUpdatesAfterStopAreIgnored() async {
        let monitor = DualCoreMonitor()
        let remote = SourceDescriptor.remote("kvm")
        let store = makeStore(monitor: monitor, sources: [.local, remote])
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot(remote: true)))
        #expect(store.sources.first { $0.id == remote.id }?.core?.online == true)
        store.setRemoteAlias("kvm", enabled: false)
        #expect(store.sources.first { $0.id == remote.id }?.hasLegacy == false)
        #expect(store.sources.first { $0.id == remote.id }?.core?.terminals.count == 1)
        await store.stopAndWait()
        await monitor.emit(.snapshot(snapshot(remote: false, terminals: [])))
        #expect(store.sources.first { $0.id == remote.id }?.core?.terminals.count == 1)
    }

    @Test
    func observerDeduplicatesNativeIDsAndKeepsCoreFailuresLocal() async {
        let monitor = DualCoreMonitor()
        let store = makeStore(monitor: monitor)
        await store.refresh()
        store.start()
        let terminal = wireTerminal("t7", .error)
        await monitor.emit(.snapshot(snapshot(terminals: [terminal, terminal])))
        #expect(store.sources[0].core?.terminals.count == 1)
        await monitor.emit(.unavailable(reason: "Core disconnected"))
        #expect(store.sources[0].online)
        #expect(store.sources[0].sessions[0].agents.count == 1)
        #expect(store.sources[0].core?.online == false)
        #expect(store.menuStatus.availability == .online)
        #expect(store.menuStatus.counts.map(\.status) == [.blocked])
        await store.stopAndWait()
    }

    @Test(arguments: [TerminalApplication.ghostty, .kero])
    func coreNavigationMustNotUseTheLegacyTerminalPreference(application: TerminalApplication) async {
        let monitor = DualCoreMonitor()
        let app = DualAppState(status: .done)
        let calls = DualNavigationCalls()
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            focusExistingClient: { _, _, _ in Issue.record("Core must not use a legacy client"); return false },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
            focusCoreApp: { target in
                await calls.record(target.id)
                await app.set(.idle)
            }, loadCoreAppSnapshot: { _ in await app.snapshot() }
        )
        await store.refresh()
        store.setTerminalApplication(application)
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)])))
        #expect(store.sources[0].core?.terminals[0].status == .done)
        store.navigate(to: .coreTerminal(coreID("t7")))
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(await calls.ids == [coreID("t7")])
        #expect(store.sources[0].core?.terminals[0].status == .idle)
        #expect(!store.menuStatus.counts.contains { $0.status == .done })
        #expect(store.successfulJumps == [.coreTerminal(coreID("t7"))])
        await store.stopAndWait()
    }

    @Test
    func appSeenNotificationsUpdateWithoutCoreEventsAndKeepRecencyStable() async {
        let monitor = DualCoreMonitor()
        let app = DualAppState(status: .done)
        let changes = AsyncThrowingStream<Void, Error>.makeStream()
        defer { changes.continuation.finish() }
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: { changes.stream },
            loadCoreAppSnapshot: { _ in await app.snapshot() }
        )
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .idle)])))
        #expect(store.sources[0].core?.terminals[0].status == .done)
        await app.set(.idle)
        changes.continuation.yield(())
        for _ in 0..<200 {
            if store.sources[0].core?.terminals[0].status == .idle { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.sources[0].core?.terminals[0].status == .idle)
        let time = store.sources[0].core?.terminals[0].updatedAt
        #expect(await store.refreshCoreAppState())
        #expect(store.sources[0].core?.terminals[0].updatedAt == time)
        await app.set(.done)
        #expect(await store.refreshCoreAppState())
        #expect(store.sources[0].core?.terminals[0].status == .done)
        await store.stopAndWait()
    }

    @Test
    func notificationDuringPendingReadGetsAFreshSnapshotAndStopIgnoresLateEvents() async {
        let monitor = DualCoreMonitor()
        let entered = AsyncStream<Void>.makeStream()
        let changes = AsyncThrowingStream<Void, Error>.makeStream()
        let release = DualNavigationGate()
        let reads = DualAppOverlapReads(entered: entered.continuation, release: release)
        defer { entered.continuation.finish(); changes.continuation.finish() }
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor,
            coreAppChanges: { changes.stream }, loadCoreAppSnapshot: { _ in await reads.load() }
        )
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)])))
        let pending = Task { await store.refreshCoreAppState() }
        var waiting = entered.stream.makeAsyncIterator()
        _ = await waiting.next()
        await reads.markSeen()
        changes.continuation.yield(())
        await release.open()
        _ = await pending.value
        for _ in 0..<200 {
            if store.sources[0].core?.terminals[0].status == .idle { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.sources[0].core?.terminals[0].status == .idle)
        #expect(await reads.count == 3)
        await store.stopAndWait()
        changes.continuation.yield(())
        #expect(await reads.count == 3)
    }

    @Test
    func failedStateNotificationsWithholdActivityUntilARefresh() async {
        let monitor = DualCoreMonitor()
        let changes = AsyncThrowingStream<Void, Error>.makeStream()
        let entered = AsyncStream<Void>.makeStream()
        let release = DualNavigationGate()
        let reads = DualAppOverlapReads(entered: entered.continuation, release: release)
        defer { entered.continuation.finish() }
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor,
            coreAppChanges: { changes.stream }, loadCoreAppSnapshot: { _ in await reads.load() }
        )
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)])))
        let pending = Task { await store.refreshCoreAppState() }
        var waiting = entered.stream.makeAsyncIterator()
        _ = await waiting.next()
        changes.continuation.finish(throwing: HerdrAppError.unavailable)
        for _ in 0..<200 {
            if store.sources[0].core?.terminals[0].status == nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.sources[0].core?.terminals[0].status == nil)
        #expect(store.sources[0].core?.online == true)
        #expect(store.menuStatus.counts.isEmpty)
        let error = store.sources[0].core?.error
        #expect(error?.contains("notifications are unavailable") == true)
        await release.open()
        _ = await pending.value
        #expect(store.sources[0].core?.terminals[0].status == nil)
        #expect(store.sources[0].core?.error == error)
        #expect(await store.refreshCoreAppState())
        #expect(store.sources[0].core?.terminals[0].status == .done)
        await store.stopAndWait()
    }

    @Test
    func unavailableOrWrongAppNeverFallsBackToRawCoreReports() async {
        let monitor = DualCoreMonitor()
        let app = DualAppState(status: .done)
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
            loadCoreAppSnapshot: { _ in try await app.availableSnapshot() }
        )
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)])))
        await app.setUnavailable()
        #expect(await !store.refreshCoreAppState())
        #expect(store.sources[0].core?.online == true)
        #expect(store.sources[0].core?.terminals[0].status == nil)
        #expect(store.menuStatus.counts.isEmpty)
        await app.setEntryCoreID("another-core")
        #expect(await !store.refreshCoreAppState())
        #expect(store.sources[0].core?.terminals[0].status == nil)
        await store.stopAndWait()
    }

    @Test
    func statusRefreshJoiningPostFocusReadCannotFailSuccessfulNavigation() async {
        let monitor = DualCoreMonitor()
        let entered = AsyncStream<Void>.makeStream()
        let pollEntered = AsyncStream<Void>.makeStream()
        let release = DualNavigationGate()
        let reads = DualAppOverlapReads(entered: entered.continuation, release: release)
        defer { entered.continuation.finish(); pollEntered.continuation.finish() }
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
            focusCoreApp: { _ in await reads.markSeen() }, loadCoreAppSnapshot: { _ in await reads.load() }
        )
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)])))
        store.navigate(to: .coreTerminal(coreID("t7")))
        var waiting = entered.stream.makeAsyncIterator()
        _ = await waiting.next()
        let poll = Task {
            pollEntered.continuation.yield(())
            return await store.refreshCoreAppState()
        }
        var started = pollEntered.stream.makeAsyncIterator()
        _ = await started.next()
        await release.open()
        #expect(await poll.value)
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(store.successfulJumps == [.coreTerminal(coreID("t7"))])
        #expect(store.sources[0].core?.terminals[0].status == .idle)
        #expect(await reads.count == 2)
        await store.stopAndWait()
    }

    @Test
    func postFocusReadCannotReuseOrBeOverwrittenByAPreFocusSnapshot() async {
        let monitor = DualCoreMonitor()
        let entered = AsyncStream<Void>.makeStream()
        let release = DualNavigationGate()
        let reads = DualAppOverlapReads(entered: entered.continuation, release: release)
        defer { entered.continuation.finish() }
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
            focusCoreApp: { _ in await reads.markSeen() }, loadCoreAppSnapshot: { _ in await reads.load() }
        )
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot(terminals: [wireTerminal("t7", .done)])))
        let poll = Task { await store.refreshCoreAppState() }
        var waiting = entered.stream.makeAsyncIterator()
        _ = await waiting.next()
        store.navigate(to: .coreTerminal(coreID("t7")))
        await navigationSettles(store)
        let phase = store.navigationAttempt?.phase
        await release.open()
        _ = await poll.value
        #expect(phase == .succeeded)
        #expect(store.sources[0].core?.terminals[0].status == .idle)
        #expect(await reads.count == 3)
        await store.stopAndWait()
    }

    @Test
    func missingAppPanePreservesItsSafeRecoveryError() async {
        let monitor = DualCoreMonitor()
        let store = SessionStore(
            client: HerdrClient(executable: nil), loadSource: { _ in [] }, loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local], defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
            focusCoreApp: { _ in throw HerdrAppError.missingPane }, loadCoreAppSnapshot: { _ in appSnapshot() }
        )
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot()))
        store.navigate(to: .coreTerminal(coreID("t7")))
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.focusError == HerdrAppError.missingPane.localizedDescription)
        await store.stopAndWait()
    }

    @Test
    func absentCoreDoesNotCreateAnOfflineRuntime() async {
        let monitor = DualCoreMonitor()
        let store = makeStore(monitor: monitor)
        await store.refresh()
        store.start()
        await monitor.emit(.absent)
        #expect(store.sources[0].core == nil)
        #expect(NavigationBrowser(sources: store.sources).offlineSourceNames.isEmpty)
        await store.stopAndWait()
    }

    @Test
    func failedFirstHandshakeIsVisibleWithoutInventingCoreIdentity() async {
        let monitor = DualCoreMonitor()
        let store = makeStore(monitor: monitor)
        await store.refresh()
        store.start()
        await monitor.emit(.unavailable(reason: "Unsupported Core protocol"))
        #expect(store.sources[0].core?.coreID == nil)
        #expect(store.sources[0].core?.error == "Unsupported Core protocol")
        #expect(store.menuStatus.availability == .online)
        #expect(NavigationBrowser(sources: store.sources).offlineSourceNames.count == 1)
        await store.stopAndWait()
    }

    @Test
    func coreGoingOfflineDuringLookupCannotCreateOrCompleteNavigation() async {
        let monitor = DualCoreMonitor()
        let started = AsyncStream<Void>.makeStream()
        let release = DualNavigationGate()
        let store = SessionStore(client: HerdrClient(executable: nil), loadSource: { _ in [] },
                                 loadBranches: { _, _ in [:] }, sourceDescriptors: [.local],
                                 defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
                                 focusCoreApp: { _ in
                                     started.continuation.yield(())
                                     await release.wait()
                                 }, loadCoreAppSnapshot: { _ in appSnapshot() })
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot()))
        store.navigate(to: .coreTerminal(coreID("t7")))
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        await monitor.emit(.unavailable(reason: "disconnected"))
        await release.open()
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.successfulJumps.isEmpty)
        started.continuation.finish()
        await store.stopAndWait()
    }

    @Test
    func waitingForHerdrAppDoesNotBlockTheMainActor() async {
        let monitor = DualCoreMonitor()
        let entered = AsyncStream<Void>.makeStream()
        let release = DualNavigationGate()
        defer { entered.continuation.finish() }
        let store = SessionStore(client: HerdrClient(executable: nil), loadSource: { _ in [] },
                                 loadBranches: { _, _ in [:] }, sourceDescriptors: [.local],
                                 defaults: PreviewFixtures.renderDefaults(), coreMonitor: monitor, coreAppChanges: quietAppChanges,
                                 focusCoreApp: { _ in
                                     entered.continuation.yield(())
                                     await release.wait()
                                 }, loadCoreAppSnapshot: { _ in appSnapshot() })
        await store.refresh()
        store.start()
        await monitor.emit(.snapshot(snapshot()))
        store.navigate(to: .coreTerminal(coreID("t7")))
        var waiting = entered.stream.makeAsyncIterator()
        _ = await waiting.next()
        #expect(store.navigationAttempt?.phase == .pending)
        await release.open()
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        await store.stopAndWait()
    }

    private func makeStore(monitor: DualCoreMonitor, sources: [SourceDescriptor] = [.local], app: HerdrAppSnapshot = appSnapshot()) -> SessionStore {
        SessionStore(client: HerdrClient(executable: nil), loadSource: { _ in
            [.init(name: "default", groups: [.init(id: "w1", name: "project", agents: [legacyAgent("t7", .blocked)])], error: nil)]
        }, loadBranches: { _, _ in [:] }, sourceDescriptors: sources, defaults: PreviewFixtures.renderDefaults(),
                     coreMonitor: monitor, coreAppChanges: quietAppChanges, loadCoreAppSnapshot: { _ in app })
    }

    private func navigationSettles(_ store: SessionStore) async {
        for _ in 0..<1_000 {
            if store.navigationAttempt?.phase != .pending { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Navigation did not settle")
    }
}

@MainActor
private func quietAppChanges() -> AsyncThrowingStream<Void, Error> { AsyncThrowingStream { _ in } }

private func coreID(_ terminal: String, core: String = "core-local") -> CoreTerminalID {
    .init(coreID: core, terminalID: terminal)
}

private func coreInfo(_ terminal: String, _ status: AgentStatus?, time: Double = 1, core: String = "core-local") -> CoreTerminalInfo {
    .init(target: .init(id: coreID(terminal, core: core), socketPath: "/tmp/dual-runtime-test.sock",
                        entryCoreID: "core-local", address: terminal), title: "same-name", status: status,
          cwd: "/same/path", updatedAt: Date(timeIntervalSince1970: time), online: true)
}

private func legacy(_ pane: String) -> NavigationDestination { .agent(sourceID: "local", sessionName: "default", paneID: pane) }
private func legacyAgent(_ pane: String, _ status: AgentStatus, time: Double = 1) -> AgentInfo {
    .init(paneID: pane, title: "same-name", status: status, workspace: "project", cwd: "/same/path", updatedAt: Date(timeIntervalSince1970: time))
}

private func mixedSource() -> SourceInfo {
    SourceInfo(descriptor: .local,
               sessions: [.init(name: "default", agents: [legacyAgent("t7", .blocked), legacyAgent("working", .working),
                                                         legacyAgent("idle", .idle, time: 9), legacyAgent("old-idle", .idle, time: 1)], online: true)],
               online: true, error: nil,
               core: .init(coreID: "core-local", terminals: [coreInfo("t7", .error), coreInfo("t1b", .idle, time: 30),
                                                           coreInfo("t9z", .idle, time: 10), coreInfo("t8", nil)],
                           online: true, error: nil, retryAt: nil))
}

private func wireTerminal(_ terminal: String, _ status: AgentStatus = .blocked, remote: Bool = false, parent: String? = nil) -> HerdrCoreTerminal {
    .init(target: .init(id: coreID(terminal, core: remote ? "core-remote" : "core-local"), socketPath: "/tmp/dual-runtime-test.sock",
                        entryCoreID: "core-local", address: remote ? "kvm/\(terminal)" : terminal),
          title: "same-name", rawStatus: status.rawValue, statusChangedAt: Date(timeIntervalSince1970: 1),
          cwd: "/same/path", machineName: remote ? "kvm" : nil, machineTarget: remote ? "kvm" : nil,
          online: true, reported: true, state: "live", statusApp: "pi", statusMessage: nil, parent: parent)
}

private func snapshot(remote: Bool = false, terminals: [HerdrCoreTerminal]? = nil) -> HerdrCoreSnapshot {
    .init(entryCoreID: "core-local", socketPath: "/tmp/dual-runtime-test.sock",
          terminals: terminals ?? [wireTerminal("t7", remote: remote)],
          machines: remote ? [.init(name: "kvm", id: "core-remote", target: "kvm", state: "connected")] : [])
}

private func appSnapshot(status: AgentStatus? = .blocked, entryCoreID: String = "core-local") -> HerdrAppSnapshot {
    .init(entryCoreID: entryCoreID, terminals: [
        .init(address: "t7", status: status, paneID: "p1", spaceID: "s1", tabID: "tab1"),
        .init(address: "kvm/t7", status: status, paneID: "p2", spaceID: "s2", tabID: "tab2"),
    ])
}

private actor DualAppState {
    private var status: AgentStatus?
    private var entryCoreID = "core-local"
    private var unavailable = false
    init(status: AgentStatus?) { self.status = status }
    func set(_ status: AgentStatus?) { self.status = status }
    func setUnavailable() { unavailable = true }
    func setEntryCoreID(_ id: String) { entryCoreID = id; unavailable = false }
    func snapshot() -> HerdrAppSnapshot { appSnapshot(status: status, entryCoreID: entryCoreID) }
    func availableSnapshot() throws -> HerdrAppSnapshot {
        guard !unavailable else { throw HerdrCoreError.unavailable("test App unavailable") }
        return snapshot()
    }
}

private actor DualAppOverlapReads {
    private let entered: AsyncStream<Void>.Continuation
    private let release: DualNavigationGate
    private(set) var count = 0
    private var seen = false
    init(entered: AsyncStream<Void>.Continuation, release: DualNavigationGate) {
        self.entered = entered
        self.release = release
    }
    func markSeen() { seen = true }
    func load() async -> HerdrAppSnapshot {
        count += 1
        let snapshot = appSnapshot(status: seen ? .idle : .done)
        if count == 2 {
            entered.yield(())
            await release.wait()
        }
        return snapshot
    }
}

private actor DualCoreMonitor: HerdrCoreMonitoring {
    private var handler: (@Sendable (HerdrCoreMonitorEvent) async -> Void)?
    private var ready: [CheckedContinuation<Void, Never>] = []
    func start(handler: @escaping @Sendable (HerdrCoreMonitorEvent) async -> Void) async {
        self.handler = handler
        ready.forEach { $0.resume() }; ready.removeAll()
    }
    func stop() async {} // Keep the callback to exercise late delivery after store shutdown.
    func retry() async {}
    func emit(_ event: HerdrCoreMonitorEvent) async {
        if handler == nil { await withCheckedContinuation { ready.append($0) } }
        await handler?(event)
    }
}

private actor DualNavigationCalls {
    private(set) var ids: [CoreTerminalID] = []
    func record(_ id: CoreTerminalID) { ids.append(id) }
}

private actor DualNavigationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}
