import Foundation
import Testing
@testable import Herdling

struct NavigationFocusTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func stoppingInvalidatesPendingAndNewNavigationUntilRestarted() async throws {
        let lookupStarted = NavigationLatch()
        let releaseLookup = NavigationLatch()
        let stopStarted = NavigationLatch()
        let releaseStop = NavigationLatch()
        let creations = NavigationCounter()
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let store = SessionStore(
            client: navigationClient(NavigationWire()),
            loadSource: { _ in [.init(name: "default", groups: [], error: nil)] },
            loadBranches: { _, _ in [:] },
            localMonitor: NavigationStopMonitor(started: stopStarted, release: releaseStop),
            focusExistingClient: { _, _, _ in
                await lookupStarted.open()
                await releaseLookup.wait()
                return false
            },
            sourceDescriptors: [.local], defaults: navigationDefaults(),
            activateClient: { _, _, _, _, _ in _ = await creations.next() }
        )
        defer {
            store.onChange = nil
            changes.continuation.finish()
            store.stop()
            Task { await releaseLookup.open(); await releaseStop.open() }
        }
        await store.refresh()
        let destination = NavigationDestination.session(sourceID: "local", sessionName: "default")
        store.navigate(to: destination)
        await lookupStarted.wait()
        let stopping = Task { await store.stopAndWait() }
        await stopStarted.wait()
        store.onChange = { changes.continuation.yield(()) }
        await releaseLookup.open()
        var completion = changes.stream.makeAsyncIterator()
        try #require(await completion.next() != nil)
        #expect(await creations.value == 0, "Quitting must invalidate a lookup before it opens a terminal")
        #expect(store.navigationAttempt == nil)
        #expect(store.focusError == nil)
        store.navigate(to: destination)
        #expect(store.navigationAttempt == nil)
        await releaseStop.open()
        await stopping.value
        store.navigate(to: destination)
        #expect(store.navigationAttempt == nil)
        #expect(await creations.value == 0)
        store.start()
        store.navigate(to: destination)
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(await creations.value == 1)
    }

    @Test
    func knownTabPreservesEstablishedClientProjectionBeforeAgentFocus() throws {
        let wire = NavigationWire()
        let client = HerdrClient(executable: "/fake/herdr", runCommand: { executable, arguments, _, input in
            wire.record(executable, arguments, input)
            return Data(#"{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fake"}],"id":"herdling-focus","result":{"pane":{"pane_id":"w1:p2"}}}"#.utf8)
        })
        try client.focus(session: "default", paneID: "w1:p2", tabID: "w1:t2")
        #expect(wire.calls.map(\.arguments) == [
            ["--session", "default", "tab", "focus", "w1:t2"],
            ["--session", "default", "agent", "focus", "w1:p2"],
        ])
        #expect(wire.calls.allSatisfy { $0.input == nil })
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func remoteErrorRemainsSanitizedEvenWhenItsSourceIsRemovedWhileAwaitingResponse() async throws {
        let snapshots = NavigationSnapshots()
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let client = HerdrClient(executable: "/fake/herdr", runCommand: { _, _, _, input in
            if input != nil {
                started.continuation.yield(())
                _ = release.wait(timeout: .now() + 3)
                throw HerdrClient.ClientError.failed("password=secret")
            }
            return Data(#"{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fake"}]}"#.utf8)
        })
        let store = SessionStore(
            client: client, loadSource: { _ in try await snapshots.load() }, loadBranches: { _, _ in [:] },
            focusExistingClient: { _, _, _ in true }, sourceDescriptors: [.local, .remote("remote")], defaults: navigationDefaults()
        )
        defer { release.signal(); started.continuation.finish() }
        await store.refresh()
        store.onClientActivated = { Issue.record("Failed focus must not dismiss the panel") }
        store.navigate(to: .agent(sourceID: "ssh:remote", sessionName: "default", paneID: "w1:p1"))
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        store.setRemoteAlias("remote", enabled: false)
        release.signal()
        await navigationSettles(store)
        #expect(store.focusError == "Remote Herdr focus failed. Check the session and SSH connection, then retry.")
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.successfulJumps.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func targetGoingOfflineDuringLookupCannotCreateAClientOrReportSuccess() async throws {
        let snapshots = NavigationSnapshots()
        let started = NavigationLatch()
        let release = NavigationLatch()
        let creations = NavigationCounter()
        let store = SessionStore(
            client: navigationClient(NavigationWire()), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] }, focusExistingClient: { _, _, _ in
                await started.open()
                await release.wait()
                return false
            }, sourceDescriptors: [.local], defaults: navigationDefaults(),
            activateClient: { _, _, _, _, _ in
                _ = await creations.next()
            }
        )
        await store.refresh()
        var activations = 0
        store.onClientActivated = { activations += 1 }
        let target = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:p1")
        store.navigate(to: target)
        await started.wait()
        await snapshots.set("source-offline")
        await store.refresh()
        await release.open()
        await navigationSettles(store)
        #expect(store.navigationAttempt?.destination == target)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.navigationAttempt?.message?.contains("offline") == true)
        #expect(store.successfulJumps.isEmpty)
        #expect(activations == 0)
        #expect(await creations.value == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func queuedTargetResolvesLatestSnapshotBeforeAnyExternalEffect() async throws {
        let snapshots = NavigationSnapshots()
        let wire = NavigationWire()
        let started = NavigationLatch()
        let release = NavigationLatch()
        let existingCalls = NavigationCounter()
        let store = SessionStore(
            client: navigationClient(wire), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] }, focusExistingClient: { _, _, _ in
                _ = await existingCalls.next()
                await started.open()
                await release.wait()
                return true
            }, sourceDescriptors: [.local], defaults: navigationDefaults()
        )
        await store.refresh()
        let oldSession = try #require(store.sources.first?.sessions.first)
        let oldAgent = try #require(oldSession.agents.first { $0.paneID == "w1:p2" })
        store.navigate(to: .agent(sourceID: "local", sessionName: "default", paneID: "w1:p1"))
        await started.wait()
        let queued = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:p2")
        store.navigate(to: queued)
        await snapshots.set("pane-gone")
        await store.refresh()
        await release.open()
        await navigationSettles(store)
        #expect(store.navigationAttempt?.destination == queued)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(await existingCalls.value == 1)
        #expect(store.successfulJumps.isEmpty)
        #expect(!wire.calls.contains { $0.input.map { String(decoding: $0, as: UTF8.self).contains("w1:p2") } == true })
        store.focus(oldAgent, in: oldSession)
        #expect(store.navigationAttempt?.destination == queued)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.pendingFocusAgentID == nil)
        #expect(await existingCalls.value == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func failedJumpRetryKeepsIdentityAndPanelDismissalDoesNotCancelPendingRequest() async throws {
        let snapshots = NavigationSnapshots()
        let existingCalls = NavigationCounter()
        let started = NavigationLatch()
        let release = NavigationLatch()
        let store = SessionStore(
            client: navigationClient(NavigationWire()), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] }, focusExistingClient: { _, _, _ in
                if await existingCalls.next() == 1 { throw GhosttyController.GhosttyError.clientCreationFailed }
                await started.open()
                await release.wait()
                return true
            }, sourceDescriptors: [.local], defaults: navigationDefaults()
        )
        await store.refresh()
        let target = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:p1")
        store.navigate(to: target)
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.navigationAttempt?.destination == target)
        #expect(store.focusError == GhosttyController.GhosttyError.clientCreationFailed.localizedDescription)
        #expect(store.successfulJumps.isEmpty)
        store.retryNavigation()
        await started.wait()
        store.setPanelOpen(true)
        store.setPanelOpen(false)
        #expect(store.navigationAttempt?.phase == .pending)
        #expect(store.navigationAttempt?.destination == target)
        await release.open()
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(store.successfulJumps == [target])
        #expect(store.focusError == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func historySurvivesOutagesButNotPaneExitOrSourceRemoval() async throws {
        let snapshots = NavigationSnapshots()
        let store = SessionStore(
            client: navigationClient(NavigationWire()), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] }, focusExistingClient: { _, _, _ in true },
            sourceDescriptors: [.local, .remote("remote")], defaults: navigationDefaults()
        )
        await store.refresh()
        let target = NavigationDestination.agent(sourceID: "ssh:remote", sessionName: "default", paneID: "w1:p1")
        store.navigate(to: target)
        await navigationSettles(store)
        #expect(store.successfulJumps == [target])
        await snapshots.set("source-offline")
        await store.refresh()
        #expect(store.successfulJumps == [target])
        await snapshots.set("pane-gone")
        await store.refresh()
        #expect(store.successfulJumps.isEmpty)
        await snapshots.set("online")
        await store.refresh()
        #expect(store.successfulJumps.isEmpty)
        store.navigate(to: target)
        await navigationSettles(store)
        #expect(store.successfulJumps == [target])
        store.setRemoteAlias("remote", enabled: false)
        #expect(store.successfulJumps.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func obsoleteClientCreationCannotReportSuccessOrEnterHistory() async throws {
        let snapshots = NavigationSnapshots()
        let wire = NavigationWire()
        let started = NavigationLatch()
        let release = NavigationLatch()
        let existingCalls = NavigationCounter()
        let store = SessionStore(
            client: navigationClient(wire), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] },
            focusExistingClient: { _, _, _ in await existingCalls.next() > 1 },
            sourceDescriptors: [.local], defaults: navigationDefaults(),
            activateClient: { _, _, _, _, _ in
                await started.open()
                await release.wait()
            }
        )
        await store.refresh()
        var activations = 0
        store.onClientActivated = { activations += 1 }
        let first = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:p1")
        let latest = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:p2")
        store.navigate(to: first)
        await started.wait()
        store.navigate(to: latest)
        store.navigate(to: latest)
        #expect(store.pendingFocusAgentID?.paneID == "w1:p2")
        await release.open()
        await navigationSettles(store)
        #expect(store.navigationAttempt?.destination == latest)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(store.focusError == nil)
        #expect(store.successfulJumps == [latest])
        #expect(activations == 1)
        #expect(await existingCalls.value == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func obsoleteFailureCannotReplaceNewerUnavailableTargetError() async throws {
        let snapshots = NavigationSnapshots()
        let started = NavigationLatch()
        let release = NavigationLatch()
        let store = SessionStore(
            client: navigationClient(NavigationWire()), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] }, focusExistingClient: { _, _, _ in
                await started.open()
                await release.wait()
                throw GhosttyController.GhosttyError.clientCreationFailed
            }, sourceDescriptors: [.local], defaults: navigationDefaults()
        )
        await store.refresh()
        store.navigate(to: .agent(sourceID: "local", sessionName: "default", paneID: "w1:p1"))
        await started.wait()
        let latest = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "gone")
        store.navigate(to: latest)
        let latestError = store.navigationAttempt?.message
        let changes = AsyncStream<Void>.makeStream()
        store.onChange = { changes.continuation.yield(()) }
        defer { store.onChange = nil; changes.continuation.finish() }
        await release.open()
        var events = changes.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(store.navigationAttempt?.destination == latest)
        #expect(store.navigationAttempt?.phase == .failed)
        #expect(store.navigationAttempt?.message == latestError)
        #expect(store.focusError == latestError)
        #expect(store.successfulJumps.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func onlyFullSuccessfulAgentJumpsEnterBoundedDeduplicatedHistory() async throws {
        let snapshots = NavigationSnapshots()
        let wire = NavigationWire()
        let store = SessionStore(
            client: navigationClient(wire), loadSource: { _ in try await snapshots.load() },
            loadBranches: { _, _ in [:] }, focusExistingClient: { _, _, _ in true },
            sourceDescriptors: [.local], defaults: navigationDefaults()
        )
        await store.refresh()
        var activations = 0
        store.onClientActivated = { activations += 1 }
        let targets = (1...4).map { NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:p\($0)") }
        for target in targets {
            store.navigate(to: target)
            await navigationSettles(store)
            try #require(store.navigationAttempt?.phase == .succeeded)
        }
        #expect(store.successfulJumps == [targets[3], targets[2], targets[1]])
        store.navigate(to: targets[1])
        await navigationSettles(store)
        #expect(store.successfulJumps == [targets[1], targets[3], targets[2]])
        store.navigate(to: .workspace(sourceID: "local", sessionName: "default", workspaceID: "w1"))
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        store.navigate(to: .session(sourceID: "local", sessionName: "default"))
        await navigationSettles(store)
        #expect(store.navigationAttempt?.phase == .succeeded)
        #expect(store.successfulJumps == [targets[1], targets[3], targets[2]])
        #expect(activations == 7)
    }

    @Test(arguments: [
        #"{"id":"other","result":{"pane":{"pane_id":"w1:p1"}}}"#,
        #"{"id":"herdling-focus"}"#,
        #"{"id":"herdling-focus","result":{"pane":{"pane_id":"w1:p2"}}}"#,
        #"{"id":"herdling-focus","error":{"message":"pane gone"},"result":{"pane":{"pane_id":"w1:p1"}}}"#,
    ])
    func paneFocusRejectsWrongIdentityMissingResultAndErrors(response: String) throws {
        let client = HerdrClient(executable: "/fake/herdr", runCommand: { _, _, _, input in
            guard input != nil else {
                return Data(#"{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fake"}]}"#.utf8)
            }
            return Data(response.utf8)
        })
        #expect(throws: (any Error).self) { try client.focus(session: "default", paneID: "w1:p1") }
    }

    @Test(.timeLimit(.minutes(1)))
    func socketTransportMatchesCompleteResponseWithoutWaitingForServerEOF() throws {
        let script = """
        IFS= read -r request
        printf '%s\\n' '{"id":"other","result":{}}' '{"event":"pane_updated"}'
        printf '%s' '{"id":"herdling-'
        sleep 0.05
        printf '%s\\n' 'focus","result":{"pane":{"pane_id":"w1:p1"}}}'
        exec /bin/sleep 30
        """
        let start = ContinuousClock.now
        let response = try HerdrClient.socketResponse(
            executable: "/bin/sh", arguments: ["-c", script],
            input: HerdrClient.paneFocusRequest(paneID: "w1:p1"), timeout: 2
        )
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(String(decoding: response, as: UTF8.self) == #"{"id":"herdling-focus","result":{"pane":{"pane_id":"w1:p1"}}}"#)
    }

    @Test(arguments: [SourceDescriptor.local, .remote("remote alias")])
    func paneFocusUsesPublicSocketAPIWithoutDependingOnTabID(source: SourceDescriptor) throws {
        let wire = NavigationWire()
        let client = HerdrClient(executable: "/fake/herdr", runCommand: { executable, arguments, _, input in
            wire.record(executable, arguments, input)
            if input == nil {
                return Data(#"{"sessions":[{"name":"work's session","running":true,"socket_path":"/tmp/work's socket"}]}"#.utf8)
            }
            return Data(#"{"id":"herdling-focus","result":{"type":"pane_info","pane":{"pane_id":"w2:p9"}}}"#.utf8)
        })
        try client.focus(source: source, session: "work's session", paneID: "w2:p9")
        let calls = wire.calls
        #expect(calls.count == 2)
        let socket = try #require(calls.last)
        let request = try #require(socket.input)
        let json = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(json["method"] as? String == "pane.focus")
        #expect((json["params"] as? [String: String]) == ["pane_id": "w2:p9"])
        #expect(request.last == 10)
        if source == .local {
            #expect(socket.executable == "/usr/bin/nc")
            #expect(socket.arguments == ["-U", "/tmp/work's socket"])
        } else {
            #expect(socket.executable == "/usr/bin/ssh")
            #expect(socket.arguments == HerdrClient.sshArguments(
                alias: "remote alias",
                command: HerdrClient.remoteShellCommand("exec nc -U '/tmp/work'\\''s socket'")
            ))
        }
    }

    @Test
    func destinationsResolveExactIdentityEvenWithDuplicateLabelsAndOfflineCache() throws {
        let remote = SourceDescriptor.remote("remote")
        let sources = [SourceDescriptor.local, remote].map { descriptor in
            SourceInfo(
                descriptor: descriptor,
                sessions: [SessionInfo(name: "default", groups: [
                    AgentGroup(id: "w1", name: "same", agents: [navigationAgent("w1:p1")]),
                    AgentGroup(id: "w2", name: "same", agents: [navigationAgent("w2:p1")]),
                ], online: descriptor == .local)],
                online: descriptor == .local,
                error: nil
            )
        }
        let destination = NavigationDestination.agent(sourceID: remote.id, sessionName: "default", paneID: "w2:p1")
        let resolved = try #require(destination.resolve(in: sources))
        #expect(resolved.destination == destination)
        #expect(resolved.source == remote)
        #expect(resolved.agent?.paneID == "w2:p1")
        #expect(resolved.group?.id == "w2")
        #expect(!resolved.isAvailable)
        #expect(NavigationDestination.workspace(sourceID: remote.id, sessionName: "default", workspaceID: "same").resolve(in: sources) == nil)
        #expect(NavigationDestination.agent(sourceID: remote.id, sessionName: "default", paneID: "absent").resolve(in: sources) == nil)
        let workspace = try #require(NavigationDestination.workspace(sourceID: "local", sessionName: "default", workspaceID: "w1").resolve(in: sources))
        #expect(workspace.isAvailable)
        #expect(workspace.group?.id == "w1")
        let session = try #require(NavigationDestination.session(sourceID: "local", sessionName: "default").resolve(in: sources))
        #expect(session.isAvailable)
    }
}

private func navigationAgent(_ paneID: String) -> AgentInfo {
    AgentInfo(paneID: paneID, title: "same agent", status: .done, workspace: "same", cwd: "", updatedAt: .now)
}

private func navigationDefaults() -> UserDefaults {
    UserDefaults(suiteName: "navigation-focus-\(UUID().uuidString)")!
}

private final class NavigationWire: @unchecked Sendable {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let input: Data?
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    func record(_ executable: String, _ arguments: [String], _ input: Data?) {
        lock.withLock { recorded.append(Call(executable: executable, arguments: arguments, input: input)) }
    }
}

private actor NavigationLatch {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

private actor NavigationCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

private actor NavigationStopMonitor: SessionMonitoring {
    let started: NavigationLatch
    let release: NavigationLatch
    init(started: NavigationLatch, release: NavigationLatch) {
        self.started = started
        self.release = release
    }
    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {}
    func stop() async {
        await started.open()
        await release.wait()
    }
}

private actor NavigationSnapshots {
    private var kind = "online"
    func set(_ kind: String) { self.kind = kind }
    func load() throws -> [HerdrClient.LoadedSession] {
        switch kind {
        case "source-offline": throw HerdrClient.ClientError.failed("offline")
        default:
            return [.init(name: "default", groups: [AgentGroup(
                id: "w1", name: "same", agents: kind == "pane-gone" ? [] : (1...4).map { navigationAgent("w1:p\($0)") }
            )], error: nil)]
        }
    }
}

private func navigationClient(_ wire: NavigationWire) -> HerdrClient {
    HerdrClient(executable: "/fake/herdr", runCommand: { executable, arguments, _, input in
        wire.record(executable, arguments, input)
        if let input {
            let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
            let paneID = try #require((request["params"] as? [String: String])?["pane_id"])
            return try JSONSerialization.data(withJSONObject: [
                "id": "herdling-focus", "result": ["type": "pane_info", "pane": ["pane_id": paneID]],
            ])
        }
        return Data(#"{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fake"}]}"#.utf8)
    })
}

@MainActor
private func navigationSettles(_ store: SessionStore) async {
    while store.navigationAttempt?.phase == .pending, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
