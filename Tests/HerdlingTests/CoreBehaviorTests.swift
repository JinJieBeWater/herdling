import AppKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Herdling

@Suite
struct CoreBehaviorTests {
    @Test @MainActor
    func refreshedAgentsContributeToMenuAttention() async {
        let defaults = PreviewFixtures.renderDefaults()
        let agents = [AgentStatus.blocked, .done, .working].map {
            AgentInfo(paneID: $0.rawValue, title: $0.rawValue, status: $0,
                      workspace: "repo", cwd: "/repo", updatedAt: .now)
        }
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadSource: { _ in [HerdrClient.LoadedSession(name: "default", groups: [
                AgentGroup(id: "repo", name: "repo", agents: agents)
            ], error: nil)] },
            loadBranches: { _, _ in [:] }, sourceDescriptors: [.local], defaults: defaults
        )
        await store.refresh()
        #expect(store.menuStatus.counts == [
            AgentStatusCount(status: .blocked, count: 1),
            AgentStatusCount(status: .done, count: 1),
            AgentStatusCount(status: .working, count: 1)
        ])
        #expect(store.navigationAttempt == nil)
    }

    @Test
    func remoteHerdrUsesLoginShellPath() throws {
        let command = HerdrClient.remoteCommand(arguments: ["session", "list", "--json"])
        #expect(command.hasPrefix("$SHELL -lc "))
        #expect(command.contains("herdr"))
        #expect(HerdrRemoteSessionMonitor.socketCommand(path: "/home/a b/herdr.sock") ==
            "exec nc -U '/home/a b/herdr.sock'")
        #expect(HerdrRemoteSessionMonitor.socketCommand(path: "/home/a'b/herdr.sock") ==
            "exec nc -U '/home/a'\\''b/herdr.sock'")
        let sessions = try HerdrClient.parseRunningSessions(Data(
            #"{"sessions":[{"name":"default","running":true,"socket_path":"/custom/herdr.sock"}]}"#.utf8
        ))
        #expect(sessions.map(\.name) == ["default"])
        #expect(sessions.map(\.socketPath) == ["/custom/herdr.sock"])
        #expect(HerdrClient.sshArguments(alias: "kvm", command: "query") == [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=4",
            "kvm", "query",
        ])
        let streamArguments = HerdrClient.sshArguments(alias: "kvm", command: "stream", keepAlive: true)
        #expect(streamArguments.contains("ServerAliveInterval=15"))
        #expect(streamArguments.contains("ServerAliveCountMax=2"))
    }

    @Test
    func remoteDiagnosticsAreClassifiedWithoutEchoingSSHOutput() {
        #expect(HerdrRemoteSessionMonitor.safeDiagnostic(
            "Permission denied (publickey). secret-token"
        ) == "SSH authentication failed.")
        #expect(HerdrRemoteSessionMonitor.safeDiagnostic(
            "remote stderr included password=hunter2"
        ) == "SSH command failed.")
        #expect(HerdrRemoteSessionMonitor.safeDiagnostic(
            "zsh: command not found: herdr"
        ) == "Herdr was not found in remote login shell.")
    }

    @Test
    func herdrGroupedOrderIsPreserved() throws {
        let snapshot = Data(#"{"result":{"snapshot":{"agents":[{"agent":"pi","agent_status":"idle","cwd":"/w1/a","foreground_cwd":null,"name":"first-w1","pane_id":"w1:p1","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w1"},{"agent":"pi","agent_status":"blocked","cwd":"/w2/a","foreground_cwd":null,"name":"first-w2","pane_id":"w2:p1","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w2"},{"agent":"pi","agent_status":"done","cwd":"/w1/b","foreground_cwd":null,"name":"second-w1","pane_id":"w1:p2","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w1"}],"workspaces":[{"label":"Workspace 2","workspace_id":"w2"},{"label":"Workspace 1","workspace_id":"w1"},{"label":"Empty","workspace_id":"w3"}]}}}"#.utf8)

        let groups = try HerdrClient.parseGroups(snapshot)
        #expect(groups.map(\.name) == ["Workspace 2", "Workspace 1", "Empty"])
        #expect(groups[0].agents.map(\.title) == ["first-w2"])
        #expect(groups[1].agents.map(\.title) == ["first-w1", "second-w1"])
        #expect(groups[2].agents.isEmpty)
    }

    @Test
    func fallbackLoadsSessionsConcurrentlyAndKeepsOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-concurrent-load-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-herdr")
        let root = HerdrClient.shellQuote(directory.path)
        let script = """
        #!/bin/sh
        if [ "$1" = session ]; then
          printf '%s\n' '{"sessions":[{"name":"a","running":true},{"name":"b","running":true}]}'
          exit 0
        fi
        touch \(root)/"$2"
        while [ ! -f \(root)/a ] || [ ! -f \(root)/b ]; do sleep 0.01; done
        printf '%s\n' '{"result":{"snapshot":{"agents":[],"workspaces":[]}}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let loaded = try await HerdrClient(executable: executable.path).load()

        #expect(loaded.map(\.name) == ["a", "b"])
        #expect(loaded.allSatisfy { $0.groups != nil })
    }

    @Test
    func commandRunnerPreservesOutputAndFailure() throws {
        let input = Data(repeating: 0x41, count: 262_144)
        #expect(try CommandRunner.run("/bin/cat", [], standardInput: input) == input)
        do {
            _ = try CommandRunner.run("/bin/sh", ["-c", "printf 'failure detail' >&2; exit 7"])
            Issue.record("Expected command failure")
        } catch CommandRunner.Error.failed(let message) {
            #expect(message == "failure detail")
        }
    }

    @Test(arguments: [false, true])
    func commandRunnerStillTimesOutAndCancels(cancel: Bool) throws {
        do {
            _ = try CommandRunner.run(
                "/bin/sleep", ["10"], timeout: 0.1, isCancelled: { cancel }
            )
            Issue.record("Expected interrupted command")
        } catch is CancellationError {
            #expect(cancel)
        } catch CommandRunner.Error.timedOut {
            #expect(!cancel)
        }
    }

    @Test
    func commandRunnerStopsProcessWhenStandardInputWriteFails() throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-command-runner-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        var childPID: pid_t?
        defer {
            if let childPID, kill(childPID, 0) == 0 { kill(childPID, SIGKILL) }
        }
        let script = "echo $$ > \(HerdrClient.shellQuote(pidURL.path)); exec 0<&-; trap '' TERM; while :; do :; done"

        do {
            _ = try CommandRunner.run(
                "/bin/sh",
                ["-c", script],
                timeout: 5,
                standardInput: Data(repeating: 0x41, count: 1_048_576)
            )
            Issue.record("Expected standard input write to fail")
        } catch CommandRunner.Error.timedOut {
            Issue.record("Standard input write blocked until timeout")
        } catch {
            let error = error as NSError
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
            #expect(underlying.domain == NSPOSIXErrorDomain)
            #expect(underlying.code == Int(EPIPE))
        }

        childPID = try pid_t(#require(Int32(
            String(contentsOf: pidURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )))
        #expect(kill(childPID!, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test(arguments: [false, true])
    func commandRunnerInterruptsBlockedInput(cancel: Bool) throws {
        let pidURL = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-input-\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let script = "echo $$ > \(HerdrClient.shellQuote(pidURL.path)); exec /bin/sleep 1"
        do {
            _ = try CommandRunner.run(
                "/bin/sh", ["-c", script], timeout: cancel ? 5 : 0.2,
                standardInput: Data(repeating: 65, count: 1_048_576),
                isCancelled: { cancel && FileManager.default.fileExists(atPath: pidURL.path) }
            )
            Issue.record("Expected blocked input to be interrupted")
        } catch is CancellationError {
            #expect(cancel)
        } catch CommandRunner.Error.timedOut {
            #expect(!cancel)
        }
        let pid = try #require(Int32(String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func olderSocketSnapshotCannotOverwriteNewerGeneration() {
        var ledger = SnapshotGenerationLedger()
        let acceptedSecond = ledger.accept(endpoint: "default", generation: 2)
        let acceptedFirst = ledger.accept(endpoint: "default", generation: 1)
        let acceptedThird = ledger.accept(endpoint: "default", generation: 3)
        #expect(acceptedSecond)
        #expect(!acceptedFirst)
        #expect(acceptedThird)
    }

    @Test
    func statusSubscriptionsAlwaysCarryRequiredPaneIDs() throws {
        let data = Data(HerdrLocalSessionMonitor.subscriptionRequest(paneIDs: ["w2:p2", "w1:p1"]).utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        let subscriptions = try #require(params["subscriptions"] as? [[String: String]])
        let statusSubscriptions = subscriptions.filter { $0["type"] == "pane.agent_status_changed" }
        let topologyTypes = Set(subscriptions.compactMap { subscription in
            subscription["pane_id"] == nil ? subscription["type"] : nil
        })

        #expect(statusSubscriptions == [
            ["type": "pane.agent_status_changed", "pane_id": "w1:p1"],
            ["type": "pane.agent_status_changed", "pane_id": "w2:p2"],
        ])
        #expect(topologyTypes.isSuperset(of: ["workspace.updated", "tab.closed"]))
        #expect(!topologyTypes.contains("layout.updated"))
    }

    @Test
    func localSocketDiscoveryKeepsDefaultThenNamedSessionOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdling-sockets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/zeta"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/alpha"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("herdr.sock").path, contents: nil)
        FileManager.default.createFile(atPath: root.appendingPathComponent("sessions/zeta/herdr.sock").path, contents: nil)
        FileManager.default.createFile(atPath: root.appendingPathComponent("sessions/alpha/herdr.sock").path, contents: nil)

        #expect(HerdrLocalSessionMonitor.endpoints(configDirectory: root) == [
            HerdrSocketEndpoint(session: "default", path: root.appendingPathComponent("herdr.sock").path),
            HerdrSocketEndpoint(session: "alpha", path: root.appendingPathComponent("sessions/alpha/herdr.sock").path),
            HerdrSocketEndpoint(session: "zeta", path: root.appendingPathComponent("sessions/zeta/herdr.sock").path),
        ])
    }

    @Test
    @MainActor
    func localSocketSnapshotBecomesAuthoritativeOverPolling() async {
        let agent = AgentInfo(
            paneID: "socket-pane", title: "socket-agent", status: .working,
            workspace: "Socket Space", cwd: "/socket", updatedAt: .now
        )
        let monitor = ImmediateSessionMonitor(event: .sessions([
            HerdrClient.LoadedSession(
                name: "default",
                groups: [AgentGroup(id: "socket", name: "Socket Space", agents: [agent])],
                error: nil
            ),
        ]))
        let recorder = SourceLoadRecorder()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            loadSource: { descriptor in recorder.load(descriptor) },
            loadBranches: { _, paths in Dictionary(uniqueKeysWithValues: paths.map { ($0, "main") }) },
            localMonitor: monitor
        )

        store.start()
        for _ in 0..<1_000 where
            store.sources[0].sessions.first?.agents.first?.paneID != "socket-pane"
                || store.sources[0].branches != ["/socket": "main"]
        {
            await Task.yield()
        }
        let callsBeforeRefresh = recorder.localCallCount
        await store.refresh()

        #expect(store.sources[0].sessions.first?.agents.first?.paneID == "socket-pane")
        #expect(store.sources[0].branches == ["/socket": "main"])
        #expect(recorder.localCallCount == callsBeforeRefresh)
        store.stop()
    }

    @Test
    @MainActor
    func remoteFailureCanRetryImmediatelyAndRecoveryClearsDiagnostic() async {
        let descriptor = SourceDescriptor.remote("kvm")
        let monitor = ManualSessionMonitor()
        let recorder = SourceLoadRecorder()
        let sleeps = SleepRecorder()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { try await sleeps.sleep($0) },
            loadSource: { recorder.load($0) },
            loadBranches: { _, _ in [:] },
            remoteMonitorFactory: { _ in monitor },
            sourceDescriptors: [descriptor]
        )
        let retryAt = Date().addingTimeInterval(30)

        store.start()
        await monitor.waitUntilStarted()
        await monitor.emit(.unavailable(reason: "SSH authentication failed.", retryAt: retryAt))
        #expect(store.sources[0].error == "SSH authentication failed.")
        #expect(store.sources[0].retryAt == retryAt)
        await store.refresh()
        #expect(recorder.remoteCallCount == 0)

        store.retryRemoteSource(descriptor)
        await monitor.waitForRetryCount(1)
        #expect(store.sources[0].error == nil)

        await monitor.emit(.sessions([loadedSession(paneID: "recovered")]))
        #expect(store.sources[0].online)
        #expect(store.sources[0].error == nil)
        #expect(store.sources[0].retryAt == nil)
        #expect(store.sources[0].sessions.first?.agents.first?.paneID == "recovered")
        await store.refresh()
        #expect(recorder.remoteCallCount == 0)
        #expect(await sleeps.durations.isEmpty)
        await store.stopAndWait()
    }

    @Test
    @MainActor
    func readdedRemoteRejectsOldMonitorEvents() async {
        let testDefaults = TestDefaults()
        let descriptor = SourceDescriptor.remote("kvm")
        let oldMonitor = ManualSessionMonitor()
        let newMonitor = ManualSessionMonitor()
        let monitors = MonitorFactoryQueue([oldMonitor, newMonitor])
        let branchStarted = AsyncGate()
        let releaseBranch = AsyncGate()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadBranches: { _, _ in
                await branchStarted.release()
                await releaseBranch.wait()
                return [:]
            },
            remoteMonitorFactory: { _ in monitors.next() },
            sourceDescriptors: [descriptor],
            defaults: testDefaults.defaults
        )

        store.start()
        await oldMonitor.waitUntilStarted()
        let staleEvent = Task { await oldMonitor.emit(.sessions([loadedSession(paneID: "old")])) }
        await branchStarted.wait()
        store.setRemoteAlias("kvm", enabled: false)
        store.setRemoteAlias("kvm", enabled: true)
        await newMonitor.waitUntilStarted()

        await releaseBranch.release()
        await staleEvent.value
        #expect(store.sources.first { $0.descriptor == descriptor }?.sessions.isEmpty == true)

        await newMonitor.emit(.sessions([loadedSession(paneID: "new")]))
        #expect(store.sources.first { $0.descriptor == descriptor }?
            .sessions.first?.agents.first?.paneID == "new")
        store.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func oldRemoteDiscoveryCannotClearRestartedDiscoveryGuard() async {
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        let secondStarted = AsyncGate()
        let releaseSecond = AsyncGate()
        let probe = DiscoveryProbe()
        let monitor = HerdrRemoteSessionMonitor(source: .remote("test"), discoverSessions: {
            let call = await probe.begin()
            if call == 1 {
                await firstStarted.release()
                await releaseFirst.wait()
            } else if call == 2 {
                await secondStarted.release()
                await releaseSecond.wait()
            }
            await probe.end()
            return .sessions([])
        })
        let oldStart = Task { await monitor.start { _ in } }
        await firstStarted.wait()
        await monitor.stop()
        let newStart = Task { await monitor.start { _ in } }
        await secondStarted.wait()
        await releaseFirst.release()
        await oldStart.value
        await monitor.retry()
        #expect(await probe.callCount == 2)
        await monitor.stop()
        await releaseSecond.release()
        await newStart.value
        #expect(await !monitor.isDiscoveryScheduled)
    }

    @Test
    func immediateRemoteRetryCoalescesWhileDiscoveryIsRunning() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let firstStarted = AsyncGate()
        let releaseFirst = AsyncGate()
        let secondStarted = AsyncGate()
        let releaseSecond = AsyncGate()
        let probe = DiscoveryProbe()
        let events = RemoteUnavailableRecorder()
        let monitor = HerdrRemoteSessionMonitor(
            source: .remote("kvm"),
            discoverSessions: {
                let call = await probe.begin()
                if call == 1 {
                    await firstStarted.release()
                    await releaseFirst.wait()
                } else if call == 2 {
                    await secondStarted.release()
                    await releaseSecond.wait()
                }
                await probe.end()
                return .failure("Permission denied (publickey). private=value")
            },
            now: { now }
        )
        let start = Task {
            await monitor.start { event in await events.record(event) }
        }

        await firstStarted.wait()
        await monitor.retry()
        await monitor.retry()
        #expect(await probe.callCount == 1)
        #expect(await probe.maximumActive == 1)

        await releaseFirst.release()
        await start.value
        await secondStarted.wait()

        #expect(await events.reasons.isEmpty)
        #expect(await events.retryDates.isEmpty)

        await releaseSecond.release()
        await events.waitForCount(1)

        #expect(await probe.callCount == 2)
        #expect(await probe.maximumActive == 1)
        #expect(await events.reasons == ["SSH authentication failed."])
        #expect(await events.retryDates == [now.addingTimeInterval(1)])
        #expect(await monitor.isDiscoveryScheduled)
        await monitor.stop()
    }

    @Test
    @MainActor
    func stopWaitsForMonitorStartupAndStopsItAgainAfterTheRace() async {
        let monitor = StartStopRaceMonitor()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            localMonitor: monitor,
            sourceDescriptors: [.local]
        )

        store.start()
        await monitor.waitUntilStartEntered()
        let stopping = Task { await store.stopAndWait() }
        await monitor.waitUntilStopped()
        await monitor.releaseStart()
        await stopping.value

        #expect(await !monitor.isActive)
        #expect(await monitor.stopCount >= 2)
    }

    @Test
    func socketEventStreamStartsWithSubscriptionAndBuffersBootstrapEvents() throws {
        let published = DispatchSemaphore(value: 0)
        let snapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Space"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"idle","name":"agent","cwd":"/repo"}]}}}"#
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "while IFS= read -r request; do case \"$request\" in *session.snapshot*) \(socketSnapshotReply(snapshot)) ;; *events.subscribe*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}' '{\"event\":\"pane_agent_status_changed\",\"data\":{\"type\":\"pane_agent_status_changed\",\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"agent_status\":\"working\"}}' ;; esac; done",
            ],
            onSnapshot: { _, _, _, groups in
                if groups.first?.agents.first?.status == .working { published.signal() }
            },
            onEnd: { _, _ in }
        )
        defer { connection.stop() }

        try connection.start()

        #expect(published.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func stoppingConnectionCancelsSnapshotProcess() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-snapshot-\(UUID()).started")
        defer { try? FileManager.default.removeItem(at: marker) }
        let completed = DispatchSemaphore(value: 0)
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: ["-c", "touch \(HerdrClient.shellQuote(marker.path)); sleep 30"],
            onSnapshot: { _, _, _, _ in },
            onEnd: { _, _ in }
        )
        Task.detached {
            _ = try? connection.start()
            completed.signal()
        }

        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        connection.stop()

        #expect(completed.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func closedPaneIsRemovedFromPublishedSnapshot() throws {
        let removed = DispatchSemaphore(value: 0)
        let snapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w6","label":"Main"}],"agents":[{"pane_id":"w6:p0","workspace_id":"w6","agent_status":"idle","name":"closed","cwd":"/repo"}]}}}"#
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "while IFS= read -r request; do case \"$request\" in *session.snapshot*) \(socketSnapshotReply(snapshot)) ;; *pane.closed*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}'; sleep 0.1; printf '%s\\n' '{\"event\":\"pane_closed\",\"data\":{\"type\":\"pane_closed\",\"pane_id\":\"w6:p0\",\"workspace_id\":\"w6\"}}' ;; esac; done",
            ],
            onSnapshot: { _, _, _, groups in
                if groups.first?.agents.isEmpty == true { removed.signal() }
            },
            onEnd: { _, _ in }
        )
        defer { connection.stop() }

        try connection.start()

        #expect(removed.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func topologyEventPublishesFreshSnapshotWithoutWaitingForDiscovery() throws {
        let refreshed = DispatchSemaphore(value: 0)
        let oldSnapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Main"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"idle","name":"old","cwd":"/repo"}]}}}"#
        let newSnapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Main"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"idle","name":"old","cwd":"/repo"},{"pane_id":"w1:p2","workspace_id":"w1","agent_status":"working","name":"new","cwd":"/repo"}]}}}"#
        let snapshots = LockedSnapshotSequence([
            try HerdrClient.parseGroups(Data(oldSnapshot.utf8)),
            try HerdrClient.parseGroups(Data(oldSnapshot.utf8)),
            try HerdrClient.parseGroups(Data(newSnapshot.utf8)),
        ])
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "while IFS= read -r request; do case \"$request\" in *pane.created*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}'; sleep 0.1; printf '%s\\n' '{\"event\":\"pane_created\",\"data\":{\"type\":\"pane_created\"}}' ;; esac; done",
            ],
            loadSnapshot: { snapshots.next() },
            onSubscriptionChange: { _, _, groups in
                if groups.flatMap(\.agents).contains(where: { $0.paneID == "w1:p2" }) {
                    refreshed.signal()
                }
            },
            onSnapshot: { _, _, _, groups in
                if groups.flatMap(\.agents).contains(where: { $0.paneID == "w1:p2" }) {
                    refreshed.signal()
                }
            },
            onEnd: { _, _ in }
        )
        defer { connection.stop() }

        try connection.start()

        #expect(refreshed.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func closedTabRemovesRemoteAgentsWithoutWaitingForDiscovery() throws {
        let refreshed = DispatchSemaphore(value: 0)
        let populatedSnapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Main"}],"agents":[{"pane_id":"w1:p1","tab_id":"tab","workspace_id":"w1","agent_status":"idle","name":"closed","cwd":"/repo"}]}}}"#
        let emptySnapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Main"}],"agents":[]}}}"#
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "count=0; while IFS= read -r request; do case \"$request\" in *session.snapshot*) count=$((count + 1)); if [ \"$count\" -ge 3 ]; then sleep 1; \(socketSnapshotReply(emptySnapshot)); else \(socketSnapshotReply(populatedSnapshot)); fi ;; *tab.closed*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}'; sleep 0.1; printf '%s\\n' '{\"event\":\"tab_closed\",\"data\":{\"type\":\"tab_closed\",\"tab_id\":\"tab\",\"workspace_id\":\"w1\"}}' ;; esac; done",
            ],
            onSubscriptionChange: { _, _, groups in
                if groups.first?.agents.isEmpty == true { refreshed.signal() }
            },
            onSnapshot: { _, _, _, groups in
                if groups.first?.agents.isEmpty == true { refreshed.signal() }
            },
            onEnd: { _, _ in }
        )
        defer { connection.stop() }

        try connection.start()

        #expect(refreshed.wait(timeout: .now() + 0.5) == .success)
    }

    @Test
    func paneUpdateAppliesWithoutAnotherSnapshotProcess() throws {
        let updated = DispatchSemaphore(value: 0)
        let snapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Main"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"idle","name":"old","cwd":"/old","revision":1}]}}}"#
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "while IFS= read -r request; do case \"$request\" in *session.snapshot*) \(socketSnapshotReply(snapshot)) ;; *pane.updated*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}'; sleep 0.1; printf '%s\\n' '{\"event\":\"pane_updated\",\"data\":{\"type\":\"pane_updated\",\"pane\":{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"agent_status\":\"working\",\"display_agent\":\"new\",\"foreground_cwd\":\"/new\",\"revision\":2}}}' ;; esac; done",
            ],
            onSnapshot: { _, _, _, groups in
                guard let current = groups.first?.agents.first else { return }
                if current.title == "new", current.status == .working, current.cwd == "/new" {
                    updated.signal()
                }
            },
            onEnd: { _, _ in }
        )
        defer { connection.stop() }

        try connection.start()

        #expect(updated.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func replayedPaneUpdateOlderThanSnapshotIsIgnored() throws {
        let staleUpdate = DispatchSemaphore(value: 0)
        let snapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Main"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"idle","name":"current","cwd":"/current","revision":6}]}}}"#
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "while IFS= read -r request; do case \"$request\" in *session.snapshot*) \(socketSnapshotReply(snapshot)) ;; *pane.updated*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}' '{\"event\":\"pane_updated\",\"data\":{\"type\":\"pane_updated\",\"pane\":{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"agent_status\":\"working\",\"display_agent\":\"stale\",\"foreground_cwd\":\"/stale\",\"revision\":2}}}' ;; esac; done",
            ],
            onSnapshot: { _, _, _, groups in
                if groups.first?.agents.first?.status == .working { staleUpdate.signal() }
            },
            onEnd: { _, _ in }
        )
        defer { connection.stop() }

        try connection.start()

        #expect(staleUpdate.wait(timeout: .now() + 0.3) == .timedOut)
    }

    @Test
    func rosterNestsWorktreesUnderExistingSpaceWithoutReordering() {
        let groups = [
            AgentGroup(id: "my", name: "my", agents: []),
            AgentGroup(id: "engineer", name: "Engineer", agents: []),
            AgentGroup(id: "engineer-wt", name: "Engineer/feature/nested", agents: []),
            AgentGroup(id: "standalone", name: "unknown/path", agents: [])
        ]

        let spaces = RosterLayout.spaces(from: groups)
        #expect(spaces.map(\.id) == ["my", "engineer", "standalone"])
        #expect(spaces[1].displayedWorktrees().map(\.id) == ["engineer", "engineer-wt"])
        #expect(spaces[1].worktreeName(spaces[1].worktrees[0]) == "feature/nested")
    }

    @Test
    func gitBranchOutputIgnoresNonRepositories() {
        let data = Data("/repo\tmain\n/tmp\t\n/worktree\tfeature/nested\n".utf8)
        #expect(GitBranchResolver.parse(data) == [
            "/repo": "main",
            "/worktree": "feature/nested",
        ])
    }

    @Test
    @MainActor
    func agentStatusTimestampTracksTransitionsRatherThanPolling() async {
        let monitor = ManualSessionMonitor()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            localMonitor: monitor,
            sourceDescriptors: [.local]
        )
        let firstSeen = Date(timeIntervalSince1970: 1_000)

        store.start()
        await monitor.waitUntilStarted()
        await monitor.emit(.sessions([loadedSession(
            paneID: "pane",
            status: .idle,
            changedAt: firstSeen
        )]))
        #expect(store.sources[0].sessions[0].agents[0].updatedAt == firstSeen)

        let workingAt = firstSeen.addingTimeInterval(60)
        await monitor.emit(.sessions([loadedSession(
            paneID: "pane",
            status: .working,
            changedAt: workingAt
        )]))
        await monitor.emit(.sessions([loadedSession(
            paneID: "pane",
            status: .working,
            changedAt: workingAt.addingTimeInterval(60)
        )]))
        #expect(store.sources[0].sessions[0].agents[0].updatedAt == workingAt)

        let idleAt = workingAt.addingTimeInterval(120)
        await monitor.emit(.sessions([loadedSession(
            paneID: "pane",
            status: .idle,
            changedAt: idleAt
        )]))
        #expect(store.sources[0].sessions[0].agents[0].updatedAt == idleAt)
        store.stop()
    }

    @Test
    @MainActor
    func sshAliasesRefreshIncludesWithoutRemovingEnabledSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let included = directory.appendingPathComponent("hosts")
        try "Include hosts\nHost first\n".write(to: config, atomically: true, encoding: .utf8)
        try "Host added\n".write(to: included, atomically: true, encoding: .utf8)
        let testDefaults = TestDefaults()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sourceDescriptors: [.local, .remote("enabled")],
            defaults: testDefaults.defaults
        )
        await store.refreshSSHAliases(at: config)
        #expect(store.availableSSHAliases == ["added", "first", "enabled"])
        try "Host replacement\n".write(to: included, atomically: true, encoding: .utf8)
        await store.refreshSSHAliases(at: config)
        #expect(store.availableSSHAliases == ["replacement", "first", "enabled"])
        #expect(store.selectedSSHAliases == ["enabled"])
        #expect(store.sources.map(\.descriptor) == [.local, .remote("enabled")])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func openingPanelRefreshesBranchAfterGitSwitchInSameDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try CommandRunner.run("/usr/bin/git", ["-C", directory.path, "init", "-b", "main"], timeout: 10)
        let resolver = GitBranchResolver(cacheDuration: 0)
        let monitor = ManualSessionMonitor()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadBranches: { source, paths in await resolver.branches(source: source, paths: paths) },
            localMonitor: monitor,
            sourceDescriptors: [.local]
        )
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        store.onChange = { changes.continuation.yield(()) }
        defer { changes.continuation.finish(); store.stop() }
        var iterator = changes.stream.makeAsyncIterator()
        store.start()
        await monitor.waitUntilStarted()
        let agent = AgentInfo(paneID: "pane", title: "pane", status: .idle, workspace: "repo", cwd: directory.path, updatedAt: .now)
        await monitor.emit(.sessions([HerdrClient.LoadedSession(
            name: "default", groups: [AgentGroup(id: "repo", name: "repo", agents: [agent])], error: nil
        )]))
        while store.sources[0].branches[directory.path] != "main" { try #require(await iterator.next() != nil) }
        store.setPanelOpen(true)
        store.setPanelOpen(false)
        _ = try CommandRunner.run("/usr/bin/git", ["-C", directory.path, "switch", "--orphan", "feature"], timeout: 10)
        store.setPanelOpen(true)
        while store.sources[0].branches[directory.path] != "feature" { try #require(await iterator.next() != nil) }
        #expect(store.sources[0].branches == [directory.path: "feature"])
    }

    @Test
    @MainActor
    func statusEventDoesNotCancelPendingBranchLoad() async {
        let monitor = ManualSessionMonitor()
        let branchStarted = AsyncGate()
        let releaseBranch = AsyncGate()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadBranches: { _, paths in
                await branchStarted.release()
                await releaseBranch.wait()
                return Dictionary(uniqueKeysWithValues: paths.map { ($0, "main") })
            },
            localMonitor: monitor,
            sourceDescriptors: [.local]
        )

        store.start()
        await monitor.waitUntilStarted()
        await monitor.emit(.sessions([loadedSession(paneID: "pane", status: .idle)]))
        await branchStarted.wait()
        await monitor.emit(.sessions([loadedSession(paneID: "pane", status: .working)]))
        await releaseBranch.release()
        for _ in 0..<1_000 where store.sources[0].branches.isEmpty { await Task.yield() }

        #expect(store.sources[0].branches == ["/remote": "main"])
        #expect(store.sources[0].sessions.first?.agents.first?.status == .working)
        store.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func emptyWorkspaceFocusUsesRealIDAndRejectsOfflineSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-workspace-focus-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-herdr")
        let argumentsURL = directory.appendingPathComponent("arguments")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(HerdrClient.shellQuote(argumentsURL.path))\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let group = AgentGroup(id: "w-real-id", name: "Engineer/my/feature", agents: [])
        let groups = [AgentGroup(id: "w-root", name: "Engineer/my", agents: []), group]
        let space = try #require(RosterLayout.spaces(from: groups).first)
        let target = try #require(space.displayedWorktrees().last)
        let monitor = ManualSessionMonitor()
        let store = SessionStore(
            client: HerdrClient(executable: executable.path),
            loadBranches: { _, _ in [:] },
            localMonitor: monitor,
            focusExistingClient: { source, name, _ in
                #expect(source == .local)
                #expect(name == "workspace session")
                return true
            },
            sourceDescriptors: [.local]
        )
        store.start()
        defer { store.stop() }
        await monitor.waitUntilStarted()
        await monitor.emit(.sessions([HerdrClient.LoadedSession(name: "workspace session", groups: groups, error: nil)]))
        await monitor.emit(.sessions([HerdrClient.LoadedSession(name: "workspace session", groups: nil, error: "offline")]))
        var session = try #require(store.sources[0].sessions.first)
        #expect(!session.online)
        var activations = 0
        store.onClientActivated = {
            activations += 1
            #expect(FileManager.default.fileExists(atPath: argumentsURL.path))
        }
        store.focusWorkspace(target.group, in: session)
        #expect(store.pendingFocusWorkspaceID == nil)
        #expect(store.pendingFocusAgentID == nil)
        #expect(activations == 0)
        #expect(!FileManager.default.fileExists(atPath: argumentsURL.path))
        await monitor.emit(.sessions([HerdrClient.LoadedSession(name: "workspace session", groups: groups, error: nil)]))
        session = try #require(store.sources[0].sessions.first)
        store.focusWorkspace(target.group, in: session)
        #expect(store.pendingFocusWorkspaceID == SessionStore.WorkspaceFocusID(sourceID: SourceDescriptor.local.id, sessionName: session.name, workspaceID: "w-real-id"))
        await waitForNavigationResult(store)
        #expect(store.pendingFocusWorkspaceID == nil)
        #expect(store.focusError == nil)
        #expect(activations == 1)
        #expect(try String(contentsOf: argumentsURL, encoding: .utf8) == "--session\nworkspace session\nworkspace\nfocus\nw-real-id\n")
    }

    @Test
    func workspaceFocusKeepsExactArgumentsThroughRemoteShellWrapping() {
        #expect(HerdrClient.shellQuote("a'b") == "'a'\\''b'")
        #expect(GhosttyController.appleScriptString("a\\\"b") == "\"a\\\\\\\"b\"")
        let arguments = HerdrClient.workspaceFocusArguments(session: "work's session", workspaceID: "w42")
        #expect(arguments == ["--session", "work's session", "workspace", "focus", "w42"])
        let command = HerdrClient.remoteCommand(arguments: arguments)
        #expect(command == HerdrClient.remoteShellCommand(
            "'herdr' '--session' 'work'\\''s session' 'workspace' 'focus' 'w42'"
        ))
        #expect(HerdrClient.sshArguments(alias: "kvm", command: command) == [
            "-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=4", "kvm", command,
        ])
    }

    @Test
    func gitBranchResolverCoalescesOverlappingPaths() async throws {
        let recorder = GatedBranchQueries()
        defer { recorder.releaseFirst.signal(); recorder.started.continuation.finish() }
        let resolver = GitBranchResolver(query: { _, paths in recorder.query(paths) })
        var starts = recorder.started.stream.makeAsyncIterator()
        let first = Task { await resolver.branches(source: .local, paths: ["/repo"]) }
        #expect(await starts.next() == ["/repo"])
        let second = Task { await resolver.branches(source: .local, paths: ["/repo", "/other"]) }
        let secondQuery = await starts.next()
        recorder.releaseFirst.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(secondQuery == ["/other"])
        #expect(firstResult["/repo"] == "first")
        #expect(secondResult == ["/repo": "first", "/other": "second"])
        #expect(await resolver.branches(source: .local, paths: ["/repo", "/other"]) == secondResult)
    }

    @Test
    func gitBranchResolverKeepsDifferentSourcesIndependent() async {
        let recorder = GatedBranchQueries()
        defer { recorder.releaseFirst.signal(); recorder.started.continuation.finish() }
        let resolver = GitBranchResolver(query: { _, paths in recorder.query(paths) })
        var starts = recorder.started.stream.makeAsyncIterator()
        let first = Task { await resolver.branches(source: .local, paths: ["/repo"]) }
        _ = await starts.next()
        let remote = await resolver.branches(source: .remote("remote"), paths: ["/repo"])
        recorder.releaseFirst.signal()
        #expect(await first.value == ["/repo": "first"])
        #expect(remote == ["/repo": "second"])
    }

    @Test
    func gitBranchResolverCachesPositiveAndNegativeResults() async {
        let recorder = BranchQueryRecorder()
        let resolver = GitBranchResolver(cacheDuration: 15) { _, paths in
            recorder.resolve(paths)
        }

        let first = await resolver.branches(source: .local, paths: ["/repo", "/tmp"])
        let second = await resolver.branches(source: .local, paths: ["/repo", "/tmp"])
        #expect(first == ["/repo": "main"])
        #expect(second == first)
        #expect(recorder.callCount == 1)
    }

    @Test
    func gitBranchResolverRetainsLastBranchWhenQueryFails() async {
        let recorder = BranchQueryRecorder()
        let resolver = GitBranchResolver(cacheDuration: 0) { _, paths in
            recorder.resolve(paths)
        }

        #expect(await resolver.branches(source: .local, paths: ["/repo"]) == ["/repo": "main"])
        recorder.failQueries()
        #expect(await resolver.branches(source: .local, paths: ["/repo"]) == ["/repo": "main"])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func workspaceFocusSharesLatestQueueAndOldAgentCannotClearItsIndicator() async throws {
        let releaseFirst = AsyncGate()
        let releaseLatest = AsyncGate()
        let calls = AsyncStream<String>.makeStream()
        let middle = AgentGroup(id: "w-middle", name: "same label", agents: [])
        let latest = AgentGroup(id: "w-latest", name: "same label", agents: [])
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadSource: { _ in [
                loadedSession(name: "first", paneID: "pane"),
                HerdrClient.LoadedSession(name: "middle", groups: [middle], error: nil),
                HerdrClient.LoadedSession(name: "latest", groups: [latest], error: nil),
            ] },
            loadBranches: { _, _ in [:] },
            focusExistingClient: { _, session, _ in
                calls.continuation.yield(session)
                if session == "first" { await releaseFirst.wait() }
                if session == "latest" { await releaseLatest.wait() }
                return true
            },
            sourceDescriptors: [.local]
        )
        await store.refresh()
        defer {
            calls.continuation.finish()
            Task { await releaseFirst.release(); await releaseLatest.release() }
        }
        let firstSession = try #require(store.sources[0].sessions.first { $0.name == "first" })
        let agent = try #require(firstSession.agents.first)
        store.focus(agent, in: firstSession)
        var callEvents = calls.stream.makeAsyncIterator()
        #expect(await callEvents.next() == "first")
        store.focusWorkspace(middle, in: SessionInfo(name: "middle", groups: [middle], online: true))
        store.focusWorkspace(latest, in: SessionInfo(name: "latest", groups: [latest], online: true))
        #expect(store.pendingFocusAgentID == nil)
        #expect(store.pendingFocusWorkspaceID?.workspaceID == "w-latest")
        await releaseFirst.release()
        #expect(await callEvents.next() == "latest")
        #expect(store.pendingFocusWorkspaceID?.workspaceID == "w-latest")
        #expect(store.focusError == nil)
        await releaseLatest.release()
        await waitForNavigationResult(store)
        #expect(store.pendingFocusAgentID == nil)
        #expect(store.pendingFocusWorkspaceID == nil)
        #expect(store.focusError == "Herdr is not installed. Install Herdr or set HERDR_BIN_PATH, then retry.")
        calls.continuation.finish()
        #expect(await callEvents.next() == nil, "Superseded middle workspace must not reach client activation")
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func disabledSourceDoesNotRunQueuedFocus() async throws {
        let started = AsyncGate()
        let release = AsyncGate()
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let testDefaults = TestDefaults()
        defer {
            changes.continuation.finish()
            Task { await release.release() }
        }
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadSource: { _ in [loadedSession(paneID: "pane")] },
            loadBranches: { _, _ in [:] },
            focusExistingClient: { source, _, _ in
                if source == .local {
                    await started.release()
                    await release.wait()
                    return true
                }
                Issue.record("Disabled source reached focus")
                throw GhosttyController.GhosttyError.clientLaunchFailed
            },
            sourceDescriptors: [.local, .remote("disabled")],
            defaults: testDefaults.defaults
        )
        await store.refresh()
        let local = try #require(store.sources.first?.sessions.first)
        let remote = try #require(store.sources.last?.sessions.first)
        let agent = try #require(local.agents.first)
        var activated = false
        store.onClientActivated = { activated = true }
        store.onChange = { changes.continuation.yield(()) }
        store.focus(agent, in: local)
        await started.wait()
        store.focus(agent, in: remote, source: .remote("disabled"))
        store.setRemoteAlias("disabled", enabled: false)
        await release.release()
        var events = changes.stream.makeAsyncIterator()
        while store.pendingFocusAgentID != nil { try #require(await events.next() != nil) }
        #expect(store.selectedSSHAliases.isEmpty)
        #expect(store.focusError == "This item is no longer available. Update the list, then retry.")
        #expect(!activated)
        await store.stopAndWait()
    }

    @Test
    func automationPermissionFailureUsesRawErrorAndKeepsDetailsPrivate() {
        for message in ["Apple event failed (-1743) secret=value", "NOT AUTHORIZED TO SEND APPLE EVENTS secret=value"] {
            let error = GhosttyController.GhosttyError.automationFailed(message)
            #expect(GhosttyController.automationPermissionFailureStatus(error) == "Denied")
            #expect(!error.localizedDescription.contains("secret"))
            #expect(!error.localizedDescription.contains("-1743"))
        }
        let failure = GhosttyController.GhosttyError.automationFailed("command failed secret=value")
        #expect(GhosttyController.automationPermissionFailureStatus(failure) == "Unavailable")
        #expect(!failure.localizedDescription.contains("secret"))
        #expect(GhosttyController.automationPermissionFailureStatus(
            NSError(domain: "test", code: -1743, userInfo: [NSLocalizedDescriptionKey: "secret=value -1743"])
        ) == "Unavailable")
        let tabFailed = GhosttyController.GhosttyError.automationFailed(
            "Ghostty rejected action new_tab. secret=value"
        )
        #expect(!tabFailed.localizedDescription.contains("secret"))
        #expect(SessionStore.focusErrorMessage(
            HerdrClient.ClientError.failed("password=hunter2"),
            remote: true
        ) == "Remote Herdr focus failed. Check the session and SSH connection, then retry.")
    }

    @Test
    func ghosttyNativeTTYFocusesTheMatchingSourceAndSession() async throws {
        let controller = GhosttyController(
            executeScript: { script, _ in
                if script.contains("every terminal") {
                    #expect(script.contains("tty of term"))
                    return "local\u{1f}/dev/ttys002\u{1e}remote\u{1f}/dev/ttys003\u{1e}"
                }
                #expect(script.contains("focus terminal id \"remote\""))
                #expect(!script.contains("new window") && !script.contains("new_tab"))
                return "focused"
            },
            runningPID: { 100 },
            loadClients: { pid, _ in
                GhosttyProcessCatalog.clients(from: """
                100 1 ?? Ghostty
                101 100 ttys002 /opt/herdr --session work
                102 100 ttys003 /opt/herdr --remote kvm --session work
                """, ghosttyPID: pid)
            }
        )
        try await controller.activateClient(source: .remote("kvm"), session: "work", command: "unused", openBehavior: .tab)
    }

    @Test(.timeLimit(.minutes(1)))
    func ghosttyCreatedClientWaitsForItsOwnNativeTTY() async throws {
        let counts = Mutex((loads: 0, queries: 0))
        let controller = GhosttyController(
            executeScript: { script, timeout in
                #expect(timeout > 0 && timeout <= 5)
                if script.contains("every terminal") {
                    return counts.withLock { state in
                        state.queries += 1
                        return state.queries == 1
                            ? "shell\u{1f}/dev/ttys000\u{1e}"
                            : "created\u{1f}/dev/ttys004\u{1e}other\u{1f}/dev/ttys003\u{1e}"
                    }
                }
                #expect(script.contains("new window with configuration cfg"))
                #expect(script.contains("herdr --session work"))
                return "created\n"
            },
            runningPID: { 100 },
            loadClients: { _, timeout in
                #expect(timeout > 0 && timeout <= 1)
                return counts.withLock { state in
                    state.loads += 1
                    if state.loads == 1 { return [] }
                    let other = GhosttyClientProcess(tty: "ttys003", sourceID: "local", session: "work")
                    if state.loads == 2 { return [other] }
                    return [other, .init(tty: "ttys004", sourceID: "local", session: "work")]
                }
            }
        )
        try await controller.activateClient(session: "work", command: "herdr --session work", openBehavior: .window)
        #expect(counts.withLock { $0.loads == 3 && $0.queries == 3 })
        #expect(try GhosttyController.remainingTime(until: .now + .seconds(60), maximum: 1) == 1)
        do {
            _ = try GhosttyController.remainingTime(until: .now - .seconds(1), maximum: 5)
            Issue.record("Expired confirmation budget allowed another command")
        } catch GhosttyController.GhosttyError.clientLaunchFailed {
        }
    }

    @Test
    func ghosttyAmbiguityAndFailedFocusNeverCreateAndReleaseTheGuard() async throws {
        let counts = Mutex((queries: 0, focuses: 0))
        let controller = GhosttyController(
            executeScript: { script, _ in
                if script.contains("every terminal") {
                    return counts.withLock { state in
                        state.queries += 1
                        return state.queries == 1
                            ? "one\u{1f}/dev/ttys003\u{1e}two\u{1f}/dev/ttys003\u{1e}"
                            : "one\u{1f}/dev/ttys003\u{1e}"
                    }
                }
                guard script.contains("focus terminal id \"one\"") else {
                    Issue.record("Unverified identity fell through to client creation")
                    throw GhosttyController.GhosttyError.clientCreationFailed
                }
                return counts.withLock { state in
                    state.focuses += 1
                    return state.focuses == 1 ? "missing" : "focused"
                }
            },
            runningPID: { 100 },
            loadClients: { _, _ in [.init(tty: "ttys003", sourceID: "local", session: "work")] }
        )
        do {
            try await controller.activateClient(session: "work", command: "unused", openBehavior: .tab)
            Issue.record("Ambiguous native TTY was accepted")
        } catch GhosttyController.GhosttyError.clientMatchFailed {
        }
        do {
            try await controller.activateClient(session: "work", command: "unused", openBehavior: .window)
            Issue.record("Failed native focus was accepted")
        } catch GhosttyController.GhosttyError.clientMatchFailed {
        }
        #expect(try await controller.focusExistingClient(session: "work"))
        #expect(counts.withLock { $0.queries == 3 && $0.focuses == 2 })
    }

    @Test
    func sshConfigFollowsIncludesAndEqualsSyntax() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdling-ssh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        try "Include config.d/*\nHost=root\nHost=equals\nHost -danger *.wild !blocked\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host included\nInclude ../config\n"
            .write(to: root.appendingPathComponent("config.d/one"), atomically: true, encoding: .utf8)

        #expect(SSHConfig.aliases(at: root.appendingPathComponent("config")) == ["included", "root", "equals"])
    }

    @Test
    @MainActor
    func panelVisibilityReschedulesPolling() async {
        let recorder = SleepRecorder()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { duration in try await recorder.sleep(duration) },
            loadSource: { _ in [] },
            loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local],
            defaults: PreviewFixtures.renderDefaults()
        )

        store.start()
        await recorder.waitForCount(1)
        let closedDurations = await recorder.durations
        #expect(closedDurations == [.seconds(15)])

        store.setPanelOpen(true)
        await recorder.waitForCount(2)
        let openDurations = await recorder.durations
        #expect(openDurations == [.seconds(15), .seconds(2)])

        await recorder.releaseFirstSleep()
        for _ in 0..<100 { await Task.yield() }
        let finalDurations = await recorder.durations
        #expect(finalDurations == [.seconds(15), .seconds(2)])
        store.stop()
    }

    @Test
    @MainActor
    func initialSourceFailureRetriesBeforeShowingError() async {
        let loader = FlakySourceLoader()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            loadSource: { try loader.load($0) }
        )

        store.start()
        for _ in 0..<1_000 where !store.sources[0].online { await Task.yield() }
        #expect(loader.callCount == 2)
        #expect(store.sources[0].online)
        #expect(store.sources[0].error == nil)
        store.stop()
    }

    @Test
    @MainActor
    func refreshPublishesSourceAndBranchesAtomically() async {
        let branchStarted = AsyncGate()
        let releaseBranch = AsyncGate()
        let agent = AgentInfo(
            paneID: "pane",
            title: "agent",
            status: .working,
            workspace: "Space",
            cwd: "/repo",
            updatedAt: .now
        )
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadSource: { _ in
                [HerdrClient.LoadedSession(
                    name: "default",
                    groups: [AgentGroup(id: "space", name: "Space", agents: [agent])],
                    error: nil
                )]
            },
            loadBranches: { _, paths in
                await branchStarted.release()
                await releaseBranch.wait()
                return Dictionary(uniqueKeysWithValues: paths.map { ($0, "main") })
            }
        )
        var changes = 0
        store.onChange = { changes += 1 }

        let refresh = Task { await store.refresh() }
        await branchStarted.wait()
        #expect(store.sources[0].sessions.isEmpty)
        #expect(changes == 0)

        await releaseBranch.release()
        await refresh.value
        #expect(store.sources[0].sessions.first?.agents.map(\.paneID) == ["pane"])
        #expect(store.sources[0].branches == ["/repo": "main"])
        #expect(changes == 1)
    }

    @Test
    @MainActor
    func panelPlacementStaysInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        let buttonRect = NSRect(x: 980, y: 280, width: 20, height: 20)
        let panelSize = StatusItemController.panelSize(
            preferred: NSSize(width: 900, height: 340),
            buttonRect: buttonRect,
            visibleFrame: visibleFrame
        )
        let origin = StatusItemController.panelOrigin(
            buttonRect: buttonRect,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        #expect(visibleFrame.contains(NSRect(origin: origin, size: panelSize)))
        #expect(panelSize.width > 0 && panelSize.height > 0)

        let narrowPanel = StatusItemController.panelSize(
            preferred: NSSize(width: 900, height: 340),
            buttonRect: NSRect(x: 480, y: 780, width: 20, height: 20),
            visibleFrame: NSRect(x: 0, y: 0, width: 500, height: 800)
        )
        #expect(narrowPanel.width > 0 && narrowPanel.width <= 500)
    }

    @Test
    @MainActor
    func visiblePanelResizeKeepsTopAndHorizontalAnchor() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let collapsed = NSRect(x: 1979, y: 1266, width: 420, height: 136)
        let expanded = StatusItemController.resizedVisiblePanelFrame(
            currentFrame: collapsed,
            preferredHeight: 1600,
            visibleFrame: visibleFrame
        )
        let collapsedAgain = StatusItemController.resizedVisiblePanelFrame(
            currentFrame: expanded,
            preferredHeight: 136,
            visibleFrame: visibleFrame
        )

        #expect(expanded.minX == collapsed.minX)
        #expect(expanded.maxY == collapsed.maxY)
        #expect(visibleFrame.contains(expanded))
        #expect(collapsedAgain.minX == collapsed.minX)
        #expect(collapsedAgain.maxY == collapsed.maxY)
    }

    @Test
    func statusButtonHitZoneIncludesScreenTop() {
        let frame = NSRect(x: 100, y: 775, width: 24, height: 20)
        #expect(PanelOutsideClickMonitor.pointHitsStatusButton(
            NSPoint(x: 112, y: 800),
            buttonFrame: frame,
            screenTop: 800
        ))
        #expect(!PanelOutsideClickMonitor.pointHitsStatusButton(
            NSPoint(x: 99, y: 800),
            buttonFrame: frame,
            screenTop: 800
        ))
    }

    @Test
    @MainActor
    func contextMenuDispatchesSettingsAndTargetsQuit() throws {
        _ = NSApplication.shared
        let probe = ContextMenuActionProbe()
        let menu = HerdlingApplicationMenu.makeContext(target: probe)
        menu.update()
        let settingsIndex = try #require(menu.items.firstIndex { $0.action == #selector(ContextMenuActionProbe.openSettings) })
        let settings = menu.items[settingsIndex]
        let quit = try #require(menu.items.first { $0.action == #selector(NSApplication.terminate(_:)) })
        #expect(settings.isEnabled)
        #expect(quit.target === NSApp)
        #expect(quit.isEnabled)
        menu.performActionForItem(at: settingsIndex)
        #expect(probe.settingsCount == 1)
    }

    @Test
    @MainActor
    func applicationMenuProvidesStandardSettingsAndQuitShortcuts() throws {
        let menu = HerdlingApplicationMenu.make(settingsTarget: NSObject())
        let appMenu = try #require(menu.items.first?.submenu)
        let settings = try #require(appMenu.items.first { $0.action == #selector(StatusItemController.openSettings) })
        let quit = try #require(appMenu.items.first { $0.action == #selector(NSApplication.terminate(_:)) })

        #expect(settings.keyEquivalent == ",")
        #expect(settings.keyEquivalentModifierMask == .command)
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == .command)
    }

    @Test
    func singleInstanceLockAllowsOnlyOneHolderAndReleasesCleanly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-lock-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(SingleInstanceLock.acquire(identifier: "test", directory: directory))
        #expect(SingleInstanceLock.acquire(identifier: "test", directory: directory) == nil)
        first.release()
        #expect(SingleInstanceLock.acquire(identifier: "test", directory: directory) != nil)
    }
}

@MainActor
private final class ContextMenuActionProbe: NSObject {
    var settingsCount = 0
    @objc func openSettings() { settingsCount += 1 }
}

private actor SleepRecorder {
    private(set) var durations: [Duration] = []
    private var firstSleepReleased = false

    func sleep(_ duration: Duration) async throws {
        let index = durations.count
        durations.append(duration)
        if index == 0 {
            while !firstSleepReleased { await Task.yield() }
            return
        }
        // Only cancellation releases later sleeps; wall time must not advance this fake clock.
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
    }

    func releaseFirstSleep() {
        firstSleepReleased = true
    }

    func waitForCount(_ count: Int) async {
        while durations.count < count { await Task.yield() }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor DiscoveryProbe {
    private(set) var callCount = 0
    private(set) var maximumActive = 0
    private var active = 0

    func begin() -> Int {
        callCount += 1
        active += 1
        maximumActive = max(maximumActive, active)
        return callCount
    }

    func end() {
        active -= 1
    }

}

private actor RemoteUnavailableRecorder {
    private(set) var reasons: [String] = []
    private(set) var retryDates: [Date] = []

    func record(_ event: SessionMonitorEvent) {
        guard case let .unavailable(reason, retryAt) = event else { return }
        if let reason { reasons.append(reason) }
        if let retryAt { retryDates.append(retryAt) }
    }

    func waitForCount(_ count: Int) async {
        while retryDates.count < count { await Task.yield() }
    }
}

private final class FlakySourceLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func load(_: SourceDescriptor) throws -> [HerdrClient.LoadedSession] {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { throw HerdrClient.ClientError.failed("herdr: command not found") }
        return []
    }
}

private final class GatedBranchQueries: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let releaseFirst = DispatchSemaphore(value: 0)
    let started = AsyncStream<[String]>.makeStream()

    func query(_ paths: [String]) -> [String: String] {
        let first = lock.withLock { count += 1; return count == 1 }
        started.continuation.yield(paths)
        if first { #expect(releaseFirst.wait(timeout: .now() + 5) == .success) }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, first ? "first" : "second") })
    }
}

private final class BranchQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failing = false

    var callCount: Int { lock.withLock { calls } }

    func resolve(_ paths: [String]) -> [String: String]? {
        lock.withLock {
            calls += 1
            return failing ? nil : paths.contains("/repo") ? ["/repo": "main"] : [:]
        }
    }

    func failQueries() {
        lock.withLock { failing = true }
    }
}

private actor ImmediateSessionMonitor: SessionMonitoring {
    let event: SessionMonitorEvent

    init(event: SessionMonitorEvent) {
        self.event = event
    }

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        await handler(event)
    }

    func stop() async {}
}

private actor ManualSessionMonitor: SessionMonitoring {
    private var handler: (@Sendable (SessionMonitorEvent) async -> Void)?
    private var retryCount = 0

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        self.handler = handler
    }

    func stop() async {
        // Deliberately retain the handler to simulate an already queued stale event.
    }

    func retry() {
        retryCount += 1
    }

    func emit(_ event: SessionMonitorEvent) async {
        await handler?(event)
    }

    func waitUntilStarted() async {
        while handler == nil { await Task.yield() }
    }

    func waitForRetryCount(_ count: Int) async {
        while retryCount < count { await Task.yield() }
    }
}

private actor StartStopRaceMonitor: SessionMonitoring {
    private var startEntered = false
    private var startReleased = false
    private(set) var isActive = false
    private(set) var stopCount = 0

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        startEntered = true
        while !startReleased { await Task.yield() }
        isActive = true
    }

    func stop() {
        stopCount += 1
        isActive = false
    }

    func waitUntilStartEntered() async {
        while !startEntered { await Task.yield() }
    }

    func waitUntilStopped() async {
        while stopCount == 0 { await Task.yield() }
    }

    func releaseStart() {
        startReleased = true
    }
}

private final class MonitorFactoryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var monitors: [ManualSessionMonitor]

    init(_ monitors: [ManualSessionMonitor]) {
        self.monitors = monitors
    }

    func next() -> any SessionMonitoring {
        lock.withLock { monitors.removeFirst() }
    }
}

private func loadedSession(
    name: String = "default",
    paneID: String,
    status: AgentStatus = .idle,
    changedAt: Date = .now
) -> HerdrClient.LoadedSession {
    let agent = AgentInfo(
        paneID: paneID,
        title: paneID,
        status: status,
        workspace: "Remote",
        cwd: "/remote",
        updatedAt: changedAt
    )
    return HerdrClient.LoadedSession(
        name: name,
        groups: [AgentGroup(id: "remote", name: "Remote", agents: [agent])],
        error: nil
    )
}

@MainActor
private func waitForNavigationResult(_ store: SessionStore) async {
    while store.navigationAttempt?.phase == .pending { await Task.yield() }
}

private final class SourceLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var localCalls = 0
    private var remoteCalls = 0

    var localCallCount: Int { lock.withLock { localCalls } }
    var remoteCallCount: Int { lock.withLock { remoteCalls } }

    func load(_ source: SourceDescriptor) -> [HerdrClient.LoadedSession] {
        lock.withLock {
            if source == .local { localCalls += 1 }
            else { remoteCalls += 1 }
        }
        return []
    }
}

private final class LockedSnapshotSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[AgentGroup]]

    init(_ snapshots: [[AgentGroup]]) {
        self.snapshots = snapshots
    }

    func next() -> [AgentGroup] {
        lock.withLock {
            guard snapshots.count > 1 else { return snapshots[0] }
            return snapshots.removeFirst()
        }
    }
}

private func socketSnapshotReply(_ snapshot: String) -> String {
    "snapshot_id=${request#*\\\"id\\\":\\\"}; snapshot_id=${snapshot_id%%\\\"*}; "
        + "printf '%s\\n' '\(snapshot)' | sed \"s/\\\"id\\\":\\\"snapshot\\\"/\\\"id\\\":\\\"$snapshot_id\\\"/\""
}

/// Temporary `UserDefaults` suite that clears itself when the test scope ends.
private final class TestDefaults {
    let defaults: UserDefaults
    private let suite: String

    init() {
        suite = "HerdlingTests.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Could not create a temporary UserDefaults suite.")
        }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }
}
