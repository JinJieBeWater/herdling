import AppKit
import Darwin
import Foundation
import Testing
@testable import Herdling

@Suite
struct CoreBehaviorTests {
    @Test
    func localSourceUsesNativeUserDisplayNameWithFallbacks() {
        #expect(SourceDescriptor.localDisplayName(
            fullName: " JinJieBeWater ",
            username: "jinjiebewater"
        ) == "JinJieBeWater")
        #expect(SourceDescriptor.localDisplayName(fullName: "", username: "jinjiebewater") == "jinjiebewater")
        #expect(SourceDescriptor.localDisplayName(fullName: "", username: "") == "Local")
    }

    @Test
    func herdrParsingAndMenuPriority() throws {
        let sessions = Data(#"{"sessions":[{"name":"default","running":true},{"name":"old","running":false}]}"#.utf8)
        #expect(try HerdrClient.parseSessions(sessions) == ["default"])

        let snapshot = Data(#"{"result":{"snapshot":{"agents":[{"agent":"pi","agent_status":"blocked","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","name":"fix auth","pane_id":"w1:p1","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w1"}],"workspaces":[{"label":"repo","workspace_id":"w1"}]}}}"#.utf8)
        let agents = try HerdrClient.parseGroups(snapshot).flatMap(\.agents)
        #expect(agents.count == 1)
        #expect(agents[0].title == "fix auth")
        #expect(agents[0].workspace == "repo")

        let source = SourceInfo(
            descriptor: .local,
            sessions: [SessionInfo(name: "default", agents: agents, online: true)],
            online: true
        )
        #expect(MenuStatus.summarize([source]) == MenuStatus(
            counts: [AgentStatusCount(status: .blocked, count: 1)],
            availability: .online
        ))
        #expect(HerdrClient.shellQuote("a'b") == "'a'\\''b'")
        #expect(GhosttyController.appleScriptString("a\\\"b") == "\"a\\\\\\\"b\"")
        #expect(try HerdrClient(executable: "/opt/homebrew/bin/herdr").attachCommand(session: "default").hasPrefix("exec /usr/bin/env "))
    }

    @Test
    @MainActor
    func ghosttyOpenBehaviorPersistsAndDefaultsToTab() {
        let suite = "HerdlingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var store = SessionStore(
            client: HerdrClient(executable: nil),
            sourceDescriptors: [.local],
            defaults: defaults
        )
        #expect(store.ghosttyOpenBehavior == .tab)

        store.setGhosttyOpenBehavior(.window)
        #expect(defaults.string(forKey: "ghostty-open-behavior") == "window")

        store = SessionStore(
            client: HerdrClient(executable: nil),
            sourceDescriptors: [.local],
            defaults: defaults
        )
        #expect(store.ghosttyOpenBehavior == .window)
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
        #expect(HerdrRemoteSessionMonitor.reconnectDelay(attempt: 1) == 1)
        #expect(HerdrRemoteSessionMonitor.reconnectDelay(attempt: 2) == 2)
        #expect(HerdrRemoteSessionMonitor.reconnectDelay(attempt: 7) == 60)
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
    func socketEventIsRecognized() throws {
        let event = Data(#"{"event":"pane.agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}}"#.utf8)
        guard case .event(.agentStatusChanged) = HerdrSocketMessage.decode(event) else {
            Issue.record("Expected socket event")
            return
        }
    }

    @Test
    func socketSubscriptionAcknowledgementIsRecognized() throws {
        let acknowledgement = Data(#"{"id":"subscription","result":{"type":"subscription_started"}}"#.utf8)
        guard case .subscriptionStarted = HerdrSocketMessage.decode(acknowledgement) else {
            Issue.record("Expected subscription acknowledgement")
            return
        }
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
    func remoteSocketMonitorReplacesPolling() async {
        let descriptor = SourceDescriptor.remote("kvm")
        let agent = AgentInfo(
            paneID: "remote-pane", title: "remote-agent", status: .idle,
            workspace: "Remote Space", cwd: "/remote", updatedAt: .now
        )
        let monitor = ImmediateSessionMonitor(event: .sessions([
            HerdrClient.LoadedSession(
                name: "default",
                groups: [AgentGroup(id: "remote", name: "Remote Space", agents: [agent])],
                error: nil
            ),
        ]))
        let recorder = SourceLoadRecorder()
        let sleepRecorder = SleepRecorder()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { duration in try await sleepRecorder.sleep(duration) },
            loadSource: { descriptor in recorder.load(descriptor) },
            loadBranches: { _, _ in [:] },
            remoteMonitorFactory: { _ in monitor },
            sourceDescriptors: [descriptor]
        )

        store.start()
        for _ in 0..<1_000 where store.sources[0].sessions.first?.agents.first?.paneID != "remote-pane" {
            await Task.yield()
        }
        await store.refresh()

        #expect(store.sources[0].sessions.first?.agents.first?.paneID == "remote-pane")
        #expect(recorder.remoteCallCount == 0)
        #expect(await sleepRecorder.durations.isEmpty)
        store.stop()
    }

    @Test
    @MainActor
    func unavailableRemoteMonitorReconnectsWithoutPolling() async {
        let descriptor = SourceDescriptor.remote("kvm")
        let monitor = ImmediateSessionMonitor(event: .unavailable())
        let recorder = SourceLoadRecorder()
        let sleepRecorder = SleepRecorder()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { duration in try await sleepRecorder.sleep(duration) },
            loadSource: { descriptor in recorder.load(descriptor) },
            remoteMonitorFactory: { _ in monitor },
            sourceDescriptors: [descriptor]
        )

        store.start()
        for _ in 0..<100 { await Task.yield() }
        await store.refresh()

        #expect(recorder.remoteCallCount == 0)
        #expect(await sleepRecorder.durations.isEmpty)
        store.stop()
    }

    @Test
    @MainActor
    func remoteFailureCanRetryImmediatelyAndRecoveryClearsDiagnostic() async {
        let descriptor = SourceDescriptor.remote("kvm")
        let monitor = ManualSessionMonitor()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            remoteMonitorFactory: { _ in monitor },
            sourceDescriptors: [descriptor]
        )
        let retryAt = Date().addingTimeInterval(30)

        store.start()
        await monitor.waitUntilStarted()
        await monitor.emit(.unavailable(reason: "SSH authentication failed.", retryAt: retryAt))
        #expect(store.sources[0].error == "SSH authentication failed.")
        #expect(store.sources[0].retryAt == retryAt)

        store.retryRemoteSource(descriptor)
        await monitor.waitForRetryCount(1)
        #expect(store.sources[0].error == nil)

        await monitor.emit(.sessions([loadedSession(paneID: "recovered")]))
        #expect(store.sources[0].online)
        #expect(store.sources[0].error == nil)
        #expect(store.sources[0].retryAt == nil)
        await store.stopAndWait()
    }

    @Test
    @MainActor
    func readdedRemoteRejectsOldMonitorEvents() async {
        let suite = "HerdlingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
            defaults: defaults
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

    @Test
    func stoppedRemoteDiscoveryDoesNotSchedulePeriodicWakeups() async {
        let discoveryStarted = AsyncGate()
        let releaseDiscovery = AsyncGate()
        let monitor = HerdrRemoteSessionMonitor(
            source: .remote("kvm"),
            discoverSessions: {
                await discoveryStarted.release()
                await releaseDiscovery.wait()
                return .sessions([])
            }
        )
        let start = Task { await monitor.start { _ in } }

        await discoveryStarted.wait()
        await monitor.stop()
        await releaseDiscovery.release()
        await start.value

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
    func socketSnapshotAndSubscriptionUseSeparateConnections() throws {
        let published = DispatchSemaphore(value: 0)
        let snapshot = #"{"id":"snapshot","result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"Space"}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"idle","name":"agent","cwd":"/repo"}]}}}"#
        let connection = HerdrSocketConnection(
            endpoint: HerdrSocketEndpoint(session: "default", path: "/unused"),
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                "IFS= read -r request; case \"$request\" in *session.snapshot*) \(socketSnapshotReply(snapshot)) ;; *events.subscribe*) printf '%s\\n' '{\"id\":\"subscription\",\"result\":{\"type\":\"subscription_started\"}}'; sleep 2 ;; esac",
            ],
            onSnapshot: { _, _, _, _ in published.signal() },
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
            AgentGroup(id: "engineer-wt", name: "Engineer/investigate-inft-50", agents: []),
            AgentGroup(id: "v5", name: "v5", agents: []),
            AgentGroup(id: "v5-wt", name: "v5/leap-309", agents: []),
            AgentGroup(id: "standalone", name: "unknown/path", agents: [])
        ]

        let spaces = RosterLayout.spaces(from: groups)
        #expect(spaces.map(\.name) == ["my", "Engineer", "v5", "unknown/path"])
        #expect(spaces[1].worktrees.map(\.name) == ["Engineer/investigate-inft-50"])
        #expect(spaces[1].worktreeName(spaces[1].worktrees[0]) == "investigate-inft-50")
        #expect(spaces[1].displayedWorktrees().map(\.name) == ["Main", "investigate-inft-50"])
        #expect(spaces[1].displayedWorktrees().map(\.id) == ["engineer", "engineer-wt"])
        #expect(spaces[1].displayedWorktrees().map(\.group.name) == ["Engineer", "Engineer/investigate-inft-50"])
        #expect(spaces[2].worktrees.map(\.name) == ["v5/leap-309"])

        let primaryAgent = AgentInfo(
            paneID: "pane", title: "agent", status: .idle, workspace: "Engineer",
            cwd: "/repo", updatedAt: .now
        )
        let populated = RosterSpace(
            primary: AgentGroup(id: "engineer", name: "Engineer", agents: [primaryAgent]),
            worktrees: [groups[2]]
        )
        #expect(populated.displayedWorktrees().map(\.name) == [
            "Main",
            "investigate-inft-50",
        ])
        #expect(populated.displayedWorktrees(showEmptyMain: false).map(\.id) == ["engineer", "engineer-wt"])
        #expect(AgentStatusCount.summarize(populated.displayedWorktrees()[0].group.agents) == [
            AgentStatusCount(status: .idle, count: 1),
        ])

        let nestedBranch = RosterLayout.spaces(from: [
            AgentGroup(id: "a", name: "A", agents: []),
            AgentGroup(id: "branch", name: "A/feature/nested", agents: [])
        ])
        #expect(nestedBranch.map(\.name) == ["A"])
        #expect(nestedBranch[0].worktreeName(nestedBranch[0].worktrees[0]) == "feature/nested")
    }

    @Test
    func singleDefaultSessionHeaderIsHidden() {
        #expect(!RosterLayout.showsSessionHeader(name: "default", sourceSessionCount: 1))
        #expect(RosterLayout.showsSessionHeader(name: "default", sourceSessionCount: 2))
        #expect(RosterLayout.showsSessionHeader(name: "work", sourceSessionCount: 1))
    }

    @Test
    func accordionAllowsAllSourcesToCollapse() {
        #expect(RosterLayout.expandedSourceID(saved: "ssh:kvm", available: ["local", "ssh:kvm"]) == "ssh:kvm")
        #expect(RosterLayout.expandedSourceID(saved: "missing", available: ["local", "ssh:kvm"]) == "local")
        #expect(RosterLayout.expandedSourceID(saved: "", available: ["local", "ssh:kvm"]) == nil)
        #expect(RosterLayout.expandedSourceID(saved: "local", available: []) == nil)
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
    func branchPathsIncludeEveryUniqueAgentCWD() {
        let first = AgentInfo(
            paneID: "p1", title: "one", status: .idle, workspace: "Space",
            cwd: "/repo", updatedAt: .now
        )
        let second = AgentInfo(
            paneID: "p2", title: "two", status: .idle, workspace: "Space",
            cwd: "/repo-worktree", updatedAt: .now
        )
        let duplicate = AgentInfo(
            paneID: "p3", title: "three", status: .idle, workspace: "Space",
            cwd: "/repo", updatedAt: .now
        )
        let space = RosterSpace(
            primary: AgentGroup(id: "root", name: "Space", agents: [first, second, duplicate]),
            worktrees: []
        )

        #expect(RosterLayout.branchSummary(
            for: space.primary.agents,
            resolved: ["/repo-worktree": "feature/nested"]
        ) == .single("feature/nested"))
        #expect(RosterLayout.branchSummary(
            for: space.primary.agents,
            resolved: ["/repo": "main", "/repo-worktree": "feature/nested"]
        ) == .mixed)
    }

    @Test
    func sourceStatusCountsHideZerosAndKeepPriorityOrder() {
        func agent(_ id: String, _ status: AgentStatus) -> AgentInfo {
            AgentInfo(
                paneID: id,
                title: id,
                status: status,
                workspace: "space",
                cwd: "/repo",
                updatedAt: .now
            )
        }

        let counts = AgentStatusCount.summarize([
            agent("idle", .idle),
            agent("blocked-1", .blocked),
            agent("working", .working),
            agent("done", .done),
            agent("blocked-2", .blocked),
            agent("unknown", .unknown),
        ])

        #expect(counts == [
            AgentStatusCount(status: .blocked, count: 2),
            AgentStatusCount(status: .done, count: 1),
            AgentStatusCount(status: .working, count: 1),
            AgentStatusCount(status: .idle, count: 1),
            AgentStatusCount(status: .unknown, count: 1),
        ])
    }

    @Test
    func recentAgentsKeepEveryAttentionItemInPriorityOrderAndExpireIdleAfterTenMinutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        let agents = [
            recentAgent("idle-old", .idle, changedAt: now.addingTimeInterval(-601)),
            recentAgent("working-1", .working, changedAt: now.addingTimeInterval(-20)),
            recentAgent("done", .done, changedAt: now.addingTimeInterval(-30)),
            recentAgent("blocked", .blocked, changedAt: now.addingTimeInterval(-40)),
            recentAgent("idle-recent", .idle, changedAt: now.addingTimeInterval(-599)),
            recentAgent("unknown", .unknown, changedAt: now),
        ] + (2...7).map { recentAgent("working-\($0)", .working, changedAt: now.addingTimeInterval(Double(-$0))) }
        let source = SourceInfo(
            descriptor: .local,
            sessions: [SessionInfo(name: "default", agents: agents, online: true)],
            online: true
        )

        let items = RecentAgentList.items(from: [source], at: now)

        #expect(items.count == 10)
        #expect(items.map(\.agent.status) == [
            .blocked, .done,
            .working, .working, .working, .working, .working, .working, .working,
            .idle,
        ])
        #expect(items.map(\.agent.title).contains("idle-old") == false)
        #expect(items.map(\.agent.title).contains("unknown") == false)
    }

    @Test
    func recentAgentIdentityIncludesSourceSessionAndPane() {
        let agent = recentAgent("shared", .working, changedAt: .now)
        let sources = [SourceDescriptor.local, .remote("kvm")].map { descriptor in
            SourceInfo(
                descriptor: descriptor,
                sessions: [SessionInfo(name: "default", agents: [agent], online: true)],
                online: true
            )
        }

        let items = RecentAgentList.items(from: sources, at: .now)

        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test
    func recentOutlineKeepsOnlySelectedAgentsAndRequiredAncestors() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        func item(_ title: String, _ status: AgentStatus, workspace: String, changedAt: Date) -> AgentInfo {
            AgentInfo(
                paneID: title,
                title: title,
                status: status,
                workspace: workspace,
                cwd: "/\(title)",
                updatedAt: changedAt
            )
        }
        let source = SourceInfo(
            descriptor: .local,
            sessions: [SessionInfo(
                name: "default",
                groups: [
                    AgentGroup(
                        id: "project",
                        name: "Project",
                        agents: [item("old", .idle, workspace: "Project", changedAt: now.addingTimeInterval(-1_801))]
                    ),
                    AgentGroup(
                        id: "feature",
                        name: "Project/feature",
                        agents: [item("active", .blocked, workspace: "Project/feature", changedAt: now)]
                    ),
                    AgentGroup(
                        id: "unrelated",
                        name: "Unrelated",
                        agents: [item("unknown", .unknown, workspace: "Unrelated", changedAt: now)]
                    ),
                    AgentGroup(id: "empty-root", name: "Empty", agents: []),
                    AgentGroup(id: "empty-worktree", name: "Project/empty", agents: []),
                ],
                online: true
            )],
            online: true,
            branches: ["/active": "feature"]
        )

        let outline = RecentAgentList.outlineSources(
            from: [source],
            items: RecentAgentList.items(from: [source], at: now)
        )
        let session = try #require(outline.first?.sessions.first)

        #expect(session.groups.map(\.name) == ["Project", "Project/feature"])
        #expect(session.groups.map(\.id) == ["project", "feature"])
        #expect(session.groups[0].agents.isEmpty)
        #expect(session.groups[1].agents.map(\.title) == ["active"])
        #expect(outline.first?.branches == ["/active": "feature"])
        let space = try #require(RosterLayout.spaces(from: session.groups).first)
        #expect(space.name == "Project")
        #expect(space.primary.id == "project")
        #expect(space.displayedWorktrees(showEmptyMain: false).map(\.id) == ["feature"])
        #expect(source.sessions[0].groups[0].agents.map(\.paneID) == ["old"])
    }

    @Test
    func recentOutlineOrdersSpacesByHighestPriorityAgent() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        func item(_ title: String, _ status: AgentStatus, workspace: String) -> AgentInfo {
            AgentInfo(
                paneID: title,
                title: title,
                status: status,
                workspace: workspace,
                cwd: "/\(title)",
                updatedAt: now
            )
        }
        let source = SourceInfo(
            descriptor: .local,
            sessions: [SessionInfo(
                name: "default",
                groups: [
                    AgentGroup(id: "a", name: "A", agents: []),
                    AgentGroup(id: "a-work", name: "A/work", agents: [item("working", .working, workspace: "A/work")]),
                    AgentGroup(id: "b", name: "B", agents: []),
                    AgentGroup(id: "b-work", name: "B/work", agents: [item("blocked", .blocked, workspace: "B/work")]),
                ],
                online: true
            )],
            online: true
        )

        let outline = RecentAgentList.outlineSources(
            from: [source],
            items: RecentAgentList.items(from: [source], at: now)
        )

        #expect(try #require(outline.first?.sessions.first).groups.map(\.name) == [
            "B", "B/work", "A", "A/work",
        ])
    }

    @Test
    @MainActor
    func recentIdleStartsAtObservedStatusTransition() async {
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
        #expect(store.recentAgents(at: firstSeen).isEmpty)

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
        #expect(store.recentAgents(at: workingAt.addingTimeInterval(60)).first?.agent.updatedAt == workingAt)

        let idleAt = workingAt.addingTimeInterval(120)
        await monitor.emit(.sessions([loadedSession(
            paneID: "pane",
            status: .idle,
            changedAt: idleAt
        )]))
        #expect(store.recentAgents(at: idleAt).map(\.agent.paneID) == ["pane"])
        #expect(store.recentAgents(at: idleAt.addingTimeInterval(600)).isEmpty)
        store.stop()
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func emptyWorkspaceFocusUsesRealIDAndRejectsOfflineSession(isNamedWorktree: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-workspace-focus-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-herdr")
        let argumentsURL = directory.appendingPathComponent("arguments")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(HerdrClient.shellQuote(argumentsURL.path))\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = HerdrClient(executable: executable.path)
        let group = AgentGroup(
            id: "w-real-id",
            name: isNamedWorktree ? "Engineer/my/feature" : "Engineer/my",
            agents: []
        )
        let groups = isNamedWorktree
            ? [AgentGroup(id: "w-root", name: "Engineer/my", agents: []), group]
            : [group]
        let space = try #require(RosterLayout.spaces(from: groups).first)
        #expect(space.displayedWorktrees().map(\.id) == (isNamedWorktree ? ["w-root", "w-real-id"] : ["w-real-id"]))
        let target = try #require(space.displayedWorktrees().last)
        #expect(target.name == (isNamedWorktree ? "feature" : "Main"))
        #expect(target.group.agents.isEmpty)
        #expect(AgentStatusCount.summarize(target.group.agents).isEmpty)
        var session = SessionInfo(name: "workspace session", groups: groups, online: false)
        let store = SessionStore(
            client: client,
            focusExistingClient: { source, name in
                #expect(source == .local)
                #expect(name == "workspace session")
                #expect(!FileManager.default.fileExists(atPath: argumentsURL.path))
                return true
            },
            sourceDescriptors: [.local]
        )
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        store.onChange = {
            completion.continuation.yield(())
            completion.continuation.finish()
        }
        defer { store.onChange = nil; completion.continuation.finish() }
        var activations = 0
        store.onClientActivated = {
            activations += 1
            #expect(!FileManager.default.fileExists(atPath: argumentsURL.path))
        }

        store.focusWorkspace(target.group, in: session)
        #expect(store.pendingFocusWorkspaceID == nil)
        #expect(store.pendingFocusAgentID == nil)
        #expect(activations == 0)

        session.online = true
        store.focusWorkspace(target.group, in: session)
        #expect(store.pendingFocusWorkspaceID == SessionStore.WorkspaceFocusID(
            sourceID: SourceDescriptor.local.id,
            sessionName: session.name,
            workspaceID: "w-real-id"
        ))
        var events = completion.stream.makeAsyncIterator()
        let completed: Void? = await events.next()
        #expect(completed != nil)
        #expect(store.pendingFocusWorkspaceID == nil)
        #expect(store.focusError == nil)
        #expect(activations == 1)
        #expect(try String(contentsOf: argumentsURL, encoding: .utf8) ==
            "--session\nworkspace session\nworkspace\nfocus\nw-real-id\n")

        try client.focus(session: session.name, paneID: "p-agent")
        #expect(try String(contentsOf: argumentsURL, encoding: .utf8) ==
            "--session\nworkspace session\nagent\nfocus\np-agent\n")
    }

    @Test
    func workspaceFocusKeepsExactArgumentsThroughRemoteShellWrapping() {
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
    func sourceBranchPathsBatchEverySessionOnce() {
        func agent(_ id: String, cwd: String, workspace: String) -> AgentInfo {
            AgentInfo(
                paneID: id,
                title: id,
                status: .idle,
                workspace: workspace,
                cwd: cwd,
                updatedAt: .now
            )
        }

        let sessions = [
            SessionInfo(
                name: "first",
                agents: [
                    agent("one", cwd: "/repo", workspace: "Space"),
                    agent("two", cwd: "/worktree", workspace: "Space/feature"),
                ],
                online: true
            ),
            SessionInfo(
                name: "second",
                agents: [
                    agent("duplicate", cwd: "/repo", workspace: "Other"),
                    agent("three", cwd: "/other", workspace: "Other"),
                ],
                online: true
            ),
        ]

        #expect(SessionStore.branchPaths(from: sessions) == ["/repo", "/worktree", "/other"])
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

    @Test
    @MainActor
    func latestRequestSupersedesEarlierFocus() async {
        let gate = AsyncGate()
        var completed: [Int] = []
        let runner = LatestRequestRunner<Int> { value in
            completed.append(value)
            if value == 1 { await gate.wait() }
        }

        runner.submit(1)
        while completed.isEmpty { await Task.yield() }
        runner.submit(2)
        runner.submit(3)
        await gate.release()
        while runner.isRunning { await Task.yield() }

        #expect(completed == [1, 3])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func workspaceFocusSharesLatestQueueAndOldAgentCannotClearItsIndicator() async throws {
        let releaseFirst = AsyncGate()
        let releaseLatest = AsyncGate()
        let calls = AsyncStream<String>.makeStream()
        let changes = AsyncStream<String>.makeStream()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            focusExistingClient: { _, session in
                calls.continuation.yield(session)
                if session == "first" { await releaseFirst.wait() }
                if session == "latest" { await releaseLatest.wait() }
                return true
            },
            sourceDescriptors: [.local]
        )
        store.onChange = { [weak store] in
            changes.continuation.yield(store?.pendingFocusWorkspaceID?.workspaceID ?? "none")
        }
        defer {
            store.onChange = nil
            calls.continuation.finish()
            changes.continuation.finish()
            Task { await releaseFirst.release(); await releaseLatest.release() }
        }
        let agent = recentAgent("pane", .idle, changedAt: .now)
        store.focus(agent, in: SessionInfo(name: "first", agents: [agent], online: true))
        var callEvents = calls.stream.makeAsyncIterator()
        #expect(await callEvents.next() == "first")

        let middle = AgentGroup(id: "w-middle", name: "same label", agents: [])
        let latest = AgentGroup(id: "w-latest", name: "same label", agents: [])
        store.focusWorkspace(middle, in: SessionInfo(name: "middle", groups: [middle], online: true))
        store.focusWorkspace(latest, in: SessionInfo(name: "latest", groups: [latest], online: true))
        #expect(store.pendingFocusAgentID == nil)
        #expect(store.pendingFocusWorkspaceID?.workspaceID == "w-latest")

        await releaseFirst.release()
        var changeEvents = changes.stream.makeAsyncIterator()
        #expect(await changeEvents.next() == "w-latest")
        #expect(await callEvents.next() == "latest")
        #expect(store.pendingFocusWorkspaceID?.workspaceID == "w-latest")

        await releaseLatest.release()
        #expect(await changeEvents.next() == "none")
        #expect(store.pendingFocusAgentID == nil)
        #expect(store.pendingFocusWorkspaceID == nil)
        #expect(store.focusError == "Herdr is not installed. Install Herdr or set HERDR_BIN_PATH, then retry.")
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func agentFocusKeepsLatestPendingUntilQueueFinishes() async {
        let releaseFirst = AsyncGate()
        let releaseLatest = AsyncGate()
        let calls = AsyncStream<String>.makeStream()
        let changes = AsyncStream<String>.makeStream()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            focusExistingClient: { _, session in
                calls.continuation.yield(session)
                if session == "first" { await releaseFirst.wait() }
                if session == "latest" { await releaseLatest.wait() }
                throw HerdrClient.ClientError.failed("session stopped")
            },
            sourceDescriptors: [.local]
        )
        store.onChange = { [weak store] in
            changes.continuation.yield(store?.pendingFocusAgentID?.paneID ?? "none")
        }
        defer {
            store.onChange = nil
            calls.continuation.finish()
            changes.continuation.finish()
        }
        let first = recentAgent("first", .idle, changedAt: .now)
        let middle = recentAgent("middle", .idle, changedAt: .now)
        let latest = recentAgent("latest", .idle, changedAt: .now)
        store.focus(first, in: SessionInfo(name: "first", agents: [first], online: true))
        #expect(store.pendingFocusAgentID == RecentAgentItem.ID(
            sourceID: SourceDescriptor.local.id,
            sessionName: "first",
            paneID: first.paneID
        ))
        var callEvents = calls.stream.makeAsyncIterator()
        #expect(await callEvents.next() == "first")

        store.focus(middle, in: SessionInfo(name: "middle", agents: [middle], online: true))
        store.focus(latest, in: SessionInfo(name: "latest", agents: [latest], online: true))
        let latestID = RecentAgentItem.ID(
            sourceID: SourceDescriptor.local.id,
            sessionName: "latest",
            paneID: latest.paneID
        )
        #expect(store.pendingFocusAgentID == latestID)

        await releaseFirst.release()
        var changeEvents = changes.stream.makeAsyncIterator()
        #expect(await changeEvents.next() == "latest")
        #expect(await callEvents.next() == "latest")
        #expect(store.pendingFocusAgentID == latestID)
        #expect(store.focusError == nil)

        await releaseLatest.release()
        #expect(await changeEvents.next() == "none")
        #expect(store.pendingFocusAgentID == nil)
        #expect(store.focusError == "Herdr focus failed: session stopped")
        calls.continuation.finish()
        #expect(await callEvents.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func failedFocusClearsPendingState() async throws {
        let releaseFailure = AsyncGate()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            focusExistingClient: { _, _ in
                await releaseFailure.wait()
                throw GhosttyController.GhosttyError.automationFailed("-1743")
            },
            sourceDescriptors: [.local]
        )
        let agent = recentAgent("pane", .idle, changedAt: .now)
        let session = SessionInfo(name: "focus-failure", agents: [agent], online: true)
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        store.onChange = {
            completion.continuation.yield(())
            completion.continuation.finish()
        }
        defer {
            store.onChange = nil
            completion.continuation.finish()
        }

        store.focus(agent, in: session)
        #expect(store.pendingFocusAgentID == RecentAgentItem.ID(
            sourceID: SourceDescriptor.local.id,
            sessionName: session.name,
            paneID: agent.paneID
        ))

        await releaseFailure.release()
        var events = completion.stream.makeAsyncIterator()
        let completed: Void? = await events.next()
        #expect(completed != nil)

        #expect(store.pendingFocusAgentID == nil)
        #expect(store.focusError ==
            "Ghostty Automation denied. Allow Herdling in System Settings → Privacy & Security → Automation.")
    }

    @Test
    func automationPermissionFailureUsesRawErrorAndKeepsDetailsPrivate() {
        for message in ["Apple event failed (-1743) secret=value", "NOT AUTHORIZED TO SEND APPLE EVENTS secret=value"] {
            let error = GhosttyController.GhosttyError.automationFailed(message)
            #expect(GhosttyController.automationPermissionFailureStatus(error) == "Denied")
            #expect(error.localizedDescription ==
                "Ghostty Automation denied. Allow Herdling in System Settings → Privacy & Security → Automation.")
            #expect(!error.localizedDescription.contains("secret"))
            #expect(!error.localizedDescription.contains("-1743"))
        }
        let failure = GhosttyController.GhosttyError.automationFailed("command failed secret=value")
        #expect(GhosttyController.automationPermissionFailureStatus(failure) == "Unavailable")
        #expect(!failure.localizedDescription.contains("secret"))
        #expect(GhosttyController.automationPermissionFailureStatus(
            GhosttyController.GhosttyError.notInstalled
        ) == "Unavailable")
        #expect(GhosttyController.automationPermissionFailureStatus(
            NSError(domain: "test", code: -1743, userInfo: [NSLocalizedDescriptionKey: "secret=value -1743"])
        ) == "Unavailable")
    }

    @Test
    func focusErrorsGiveActionsWithoutEchoingRemoteOrAutomationDetails() {
        let denied = GhosttyController.GhosttyError.automationFailed(
            "Not authorized to send Apple events. secret=value (-1743)"
        )
        let tabFailed = GhosttyController.GhosttyError.automationFailed(
            "Ghostty rejected action new_tab. secret=value"
        )

        #expect(denied.localizedDescription.contains("System Settings → Privacy & Security → Automation"))
        #expect(!denied.localizedDescription.contains("secret"))
        #expect(tabFailed.localizedDescription.contains("Window in Settings"))
        #expect(!tabFailed.localizedDescription.contains("secret"))
        #expect(SessionStore.focusErrorMessage(
            HerdrClient.ClientError.failed("password=hunter2"),
            remote: true
        ) == "Remote Herdr focus failed. Check the session and SSH connection, then retry.")
    }

    @Test
    func ghosttyStorageKeysCannotCollideAcrossSourceAndSession() {
        let first = GhosttyController.mappingKey(source: .remote("a"), session: "b.c")
        let second = GhosttyController.mappingKey(source: .remote("a.b"), session: "c")
        #expect(first != second)
    }

    @Test
    func mappedGhosttyTerminalRequiresMatchingLiveClient() {
        let mapping = GhosttyController.ClientMapping(terminalID: "terminal", tty: "ttys000")
        let matching = GhosttyClientProcess(tty: "ttys000", sourceID: "ssh:kvm", session: "default")
        let wrongSession = GhosttyClientProcess(tty: "ttys000", sourceID: "ssh:kvm", session: "other")

        #expect(GhosttyController.reusableMappedTerminalID(
            mapping: mapping,
            clients: [matching],
            sourceID: "ssh:kvm",
            session: "default"
        ) == "terminal")
        #expect(GhosttyController.reusableMappedTerminalID(
            mapping: mapping,
            clients: [],
            sourceID: "ssh:kvm",
            session: "default"
        ) == nil)
        #expect(GhosttyController.reusableMappedTerminalID(
            mapping: mapping,
            clients: [wrongSession],
            sourceID: "ssh:kvm",
            session: "default"
        ) == nil)
    }

    @Test
    func createdGhosttyClientWaitsForNewMatchingTTY() {
        let clients = [
            GhosttyClientProcess(tty: "ttys000", sourceID: "ssh:kvm", session: "default"),
            GhosttyClientProcess(tty: "ttys001", sourceID: "ssh:kvm", session: "default"),
            GhosttyClientProcess(tty: "ttys002", sourceID: "local", session: "default"),
        ]

        #expect(GhosttyController.newClientTTYs(
            clients: clients,
            excluding: ["ttys000"],
            sourceID: "ssh:kvm",
            session: "default"
        ) == ["ttys001"])
    }

    @Test
    func legacyGhosttyMappingDecodesWithoutTTY() throws {
        let mapping = try JSONDecoder().decode(
            GhosttyController.ClientMapping.self,
            from: Data(#"{"terminalID":"terminal"}"#.utf8)
        )

        #expect(mapping == GhosttyController.ClientMapping(terminalID: "terminal"))
    }

    @Test
    func existingHerdrTerminalUsesProbeWhenShellMakesCountsAmbiguous() {
        #expect(GhosttyController.adoptableTerminalID(
            liveTerminalIDs: ["local-terminal", "remote-terminal"],
            claimedTerminalIDs: ["remote-terminal"],
            allClientTTYs: ["ttys000", "ttys021"],
            targetTTYs: ["ttys000"]
        ) == "local-terminal")

        #expect(GhosttyController.adoptableTerminalID(
            liveTerminalIDs: ["shell", "local-terminal", "remote-terminal"],
            claimedTerminalIDs: ["remote-terminal"],
            allClientTTYs: ["ttys000", "ttys021"],
            targetTTYs: ["ttys000"],
            probedTerminalID: "local-terminal"
        ) == "local-terminal")

        #expect(GhosttyController.adoptableTerminalID(
            liveTerminalIDs: ["target-terminal"],
            claimedTerminalIDs: ["target-terminal"],
            allClientTTYs: ["ttys000"],
            targetTTYs: ["ttys000"],
            probedTerminalID: "target-terminal"
        ) == "target-terminal")
    }

    @Test
    func ghosttyClientCatalogKeepsExactSourceAndSession() {
        let output = """
         100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
         110 100 ttys000 /usr/bin/login -flp user /bin/zsh
         111 110 ttys000 /opt/homebrew/bin/herdr --session default
         120 100 ttys021 /usr/bin/login -flp user /bin/zsh
         121 120 ttys021 /opt/homebrew/bin/herdr --remote kvm --session work
         130 1 ttys009 /opt/homebrew/bin/herdr --session default
        """

        #expect(GhosttyProcessCatalog.clients(from: output, ghosttyPID: 100) == [
            GhosttyClientProcess(tty: "ttys000", sourceID: "local", session: "default"),
            GhosttyClientProcess(tty: "ttys021", sourceID: "ssh:kvm", session: "work"),
        ])
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
        let store = SessionStore(client: HerdrClient(executable: nil)) { duration in
            try await recorder.sleep(duration)
        }

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
        #expect(await recorder.durations.count == 2)
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
    func statusItemOwnsNativeLayoutAndAccessibility() {
        let status = MenuStatus(
            counts: [
                AgentStatusCount(status: .done, count: 1),
                AgentStatusCount(status: .working, count: 4),
                AgentStatusCount(status: .idle, count: 15),
            ],
            availability: .online
        )
        let presentation = MenuBarStatusPresentation.for(status)
        #expect(presentation.entries.map(\.statusSymbol) == [
            "checkmark.circle.fill",
            "circle.lefthalf.filled",
            "circle",
        ])
        #expect(presentation.entries.compactMap(\.count) == [1, 4, 15])
        #expect(presentation.accessibilityText == "Herdling, 1 completed agent, 4 working agents, 15 idle agents")
        #expect(MenuBarStatusPresentation.for(
            MenuStatus(counts: [], availability: .loading)
        ).entries.first?.statusSymbol == "ellipsis")
        #expect(MenuBarStatusPresentation.for(
            MenuStatus(counts: [], availability: .offline)
        ).entries.first?.statusSymbol == "wifi.slash")
        #expect(MenuBarStatusPresentation.for(
            MenuStatus(counts: [], availability: .online)
        ).entries.first?.statusSymbol == "circle.dotted")

        let statusItem = MenuBarStatusItem()
        defer { NSStatusBar.system.removeStatusItem(statusItem.item) }
        statusItem.update(status)
        #expect(statusItem.item.length > 50)
        #expect(statusItem.item.button?.accessibilityLabel() == presentation.accessibilityText)
        #expect(statusItem.item.button?.image?.isTemplate == true)
        #expect(MenuBarStatusItem.renderingScale(buttonScale: 1, fallbackScale: 2) == 1)
        #expect(MenuBarStatusItem.renderingScale(buttonScale: nil, fallbackScale: 2) == 2)
    }

    @Test
    func rosterWorkingColorUsesSystemAccent() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        var accent: NSColor?
        var working: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            working = StatusPalette.working.usingColorSpace(.sRGB)
        }
        #expect(working == accent)
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
        #expect(panelSize == NSSize(width: 900, height: 255))
        #expect(origin == NSPoint(x: 92, y: 25))
        #expect(origin.y + panelSize.height <= visibleFrame.maxY)

        let narrowPanel = StatusItemController.panelSize(
            preferred: NSSize(width: 900, height: 340),
            buttonRect: NSRect(x: 480, y: 780, width: 20, height: 20),
            visibleFrame: NSRect(x: 0, y: 0, width: 500, height: 800)
        )
        #expect(narrowPanel.width == 484)
        #expect(narrowPanel.width - 36 > 0)
    }

    @Test
    @MainActor
    func panelHeightTracksContentWithinBounds() {
        #expect(PanelHeightMeasurement(header: 39.5, body: 205.25).total == 244.75)
        #expect(StatusItemController.clampedContentHeight(20) == 100)
        #expect(StatusItemController.clampedContentHeight(245.2) == 246)
        #expect(StatusItemController.clampedContentHeight(900) == 900)
        #expect(StatusItemController.maximumPanelHeight(
            topY: 800,
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800)
        ) == 680)
        #expect(StatusItemController.maximumPanelHeight(
            topY: 700,
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 700)
        ) == 595)
        #expect(StatusItemController.maximumPanelHeight(
            topY: 200,
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800)
        ) == 184)

        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let buttonRect = NSRect(x: 900, y: 780, width: 20, height: 20)
        let fullHeightSize = StatusItemController.panelSize(
            preferred: NSSize(width: 420, height: 900),
            buttonRect: NSRect(x: 900, y: 800, width: 20, height: 20),
            visibleFrame: visibleFrame
        )
        #expect(fullHeightSize.height == 680)
        #expect(StatusItemController.panelTopY(
            buttonRect: NSRect(x: 900, y: 800, width: 20, height: 20),
            visibleFrame: visibleFrame
        ) == visibleFrame.maxY)
        let compactSize = NSSize(width: 900, height: 200)
        let expandedSize = NSSize(width: 900, height: 500)
        let compactOrigin = StatusItemController.panelOrigin(
            buttonRect: buttonRect,
            panelSize: compactSize,
            visibleFrame: visibleFrame
        )
        let expandedOrigin = StatusItemController.panelOrigin(
            buttonRect: buttonRect,
            panelSize: expandedSize,
            visibleFrame: visibleFrame
        )
        #expect(compactOrigin.y + compactSize.height == expandedOrigin.y + expandedSize.height)
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
        #expect(expanded.height == floor(visibleFrame.height * StatusItemController.panelScreenFraction))
        #expect(expanded.minY == collapsed.maxY - expanded.height)
        #expect(collapsedAgain.minX == collapsed.minX)
        #expect(collapsedAgain.maxY == collapsed.maxY)
    }

    @Test
    @MainActor
    func sourceSelectionImmediatelyNotifiesStatusItem() {
        let store = SessionStore(client: HerdrClient(executable: nil))
        var changes = 0
        store.onChange = { changes += 1 }
        store.setRemoteAlias("missing", enabled: false)
        #expect(changes == 1)
        store.stop()
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
    func panelEscapeReturnsFromSettingsBeforeClosing() {
        #expect(StatusItemController.escapeAction(showingSettings: true) == .showRoster)
        #expect(StatusItemController.escapeAction(showingSettings: false) == .closePanel)
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
        try await Task.sleep(for: .seconds(30))
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

private func recentAgent(_ title: String, _ status: AgentStatus, changedAt: Date) -> AgentInfo {
    AgentInfo(
        paneID: title,
        title: title,
        status: status,
        workspace: "Space",
        cwd: "/repo",
        updatedAt: changedAt
    )
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
