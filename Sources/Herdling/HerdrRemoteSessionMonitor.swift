import Foundation

actor HerdrRemoteSessionMonitor: SessionMonitoring {
    static let discoveryInterval: Duration = .seconds(60)

    enum DiscoveryResult: Sendable {
        case sessions([HerdrClient.RunningSession])
        case failure(String)
    }

    private let source: SourceDescriptor
    private let discoverSessions: @Sendable () async -> DiscoveryResult
    private let now: @Sendable () -> Date
    private let roster = HerdrSocketRoster()
    private var discoveryTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isDiscovering = false
    private var immediateRetryRequested = false
    private var lifecycleGeneration: UInt64?
    private var discoveryScheduleGeneration: UInt64 = 0

    init(
        source: SourceDescriptor,
        client: HerdrClient = HerdrClient(),
        discoverSessions: (@Sendable () async -> DiscoveryResult)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(source.sshAlias != nil)
        self.source = source
        self.now = now
        self.discoverSessions = discoverSessions ?? {
            await Task.detached {
                do { return .sessions(try client.runningSessions(source)) }
                catch { return .failure(error.localizedDescription) }
            }.value
        }
    }

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        guard lifecycleGeneration == nil else { return }
        let generation = await roster.start(handler: handler)
        lifecycleGeneration = generation
        await discover(generation: generation)
    }

    func stop() async {
        lifecycleGeneration = nil
        discoveryScheduleGeneration &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        reconnectAttempt = 0
        isDiscovering = false
        immediateRetryRequested = false
        await roster.stop()
    }

    static func socketCommand(path: String) -> String {
        "exec nc -U \(HerdrClient.shellQuote(path))"
    }

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(attempt, 1) - 1)), 60)
    }

    var isDiscoveryScheduled: Bool { discoveryTask != nil }

    func retry() async {
        guard let generation = lifecycleGeneration else { return }
        discoveryScheduleGeneration &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        guard !isDiscovering else {
            immediateRetryRequested = true
            return
        }
        await discover(generation: generation)
    }

    private func discover(generation: UInt64) async {
        guard await roster.isActive(generation), !isDiscovering else { return }
        isDiscovering = true
        defer {
            if lifecycleGeneration == generation {
                isDiscovering = false
                if immediateRetryRequested, lifecycleGeneration != nil {
                    immediateRetryRequested = false
                    scheduleDiscovery(after: .zero, generation: generation)
                }
            }
        }
        let result = await discoverSessions()
        guard await roster.isActive(generation) else { return }
        guard case let .sessions(sessions) = result else {
            let reason = if case let .failure(message) = result {
                Self.safeDiagnostic(message)
            } else {
                "SSH command failed."
            }
            await scheduleReconnect(reason: reason, generation: generation)
            return
        }

        let endpoints = sessions.map {
            HerdrSocketEndpoint(session: $0.name, path: $0.socketPath)
        }
        let topologyChanged = await roster.reconcileEndpoints(endpoints)
        let existing = await roster.existingConnections(endpoints)
        let refreshResults = await HerdrSocketConnection.refreshAll(existing)
        guard await roster.isActive(generation) else { return }
        for result in refreshResults where !result.succeeded {
            await roster.removeConnection(at: result.path, connectionID: result.connectionID)
        }
        var pending: [(HerdrSocketEndpoint, HerdrSocketConnection)] = []
        for endpoint in endpoints {
            guard await !roster.hasConnection(at: endpoint.path) else { continue }
            guard let connection = makeConnection(endpoint) else { continue }
            await roster.addConnection(connection, for: endpoint)
            pending.append((endpoint, connection))
        }
        let failure = await startConnections(pending, generation: generation)
        guard await roster.isActive(generation) else { return }
        if topologyChanged || !pending.isEmpty { await roster.publishSessions() }
        if let failure {
            await scheduleReconnect(reason: failure, generation: generation)
        } else {
            reconnectAttempt = 0
            scheduleDiscovery(after: Self.discoveryInterval, generation: generation)
        }
    }

    private func makeConnection(_ endpoint: HerdrSocketEndpoint) -> HerdrSocketConnection? {
        guard let alias = source.sshAlias else { return nil }
        return HerdrSocketConnection(
            endpoint: endpoint,
            eventExecutable: "/usr/bin/ssh",
            eventArguments: HerdrClient.sshArguments(
                alias: alias,
                command: HerdrClient.remoteShellCommand(Self.socketCommand(path: endpoint.path)),
                keepAlive: true
            ),
            onSubscriptionChange: { [weak self] connectionID, endpoint, groups in
                Task {
                    await self?.subscriptionChanged(
                        groups,
                        at: endpoint,
                        connectionID: connectionID
                    )
                }
            },
            onSnapshot: { [weak self] connectionID, endpoint, generation, groups in
                Task {
                    await self?.received(
                        groups,
                        from: endpoint,
                        connectionID: connectionID,
                        generation: generation
                    )
                }
            },
            onEnd: { [weak self] connectionID, endpoint in
                Task { await self?.ended(endpoint: endpoint, connectionID: connectionID) }
            }
        )
    }

    private func startConnections(
        _ pending: [(HerdrSocketEndpoint, HerdrSocketConnection)],
        generation: UInt64
    ) async -> String? {
        guard !pending.isEmpty else { return nil }
        var failure: String?
        let results = await HerdrSocketConnection.startAll(pending)
        for result in results {
            guard await roster.isActive(generation) else { continue }
            guard !result.succeeded else { continue }
            guard await roster.removeConnection(
                at: result.path,
                connectionID: result.connectionID
            ) else { continue }
            failure = failure ?? Self.safeStreamDiagnostic(result.failureReason)
        }

        return failure
    }

    private func received(
        _ groups: [AgentGroup],
        from endpoint: HerdrSocketEndpoint,
        connectionID: UUID,
        generation: UInt64
    ) async {
        await roster.receive(
            groups,
            from: endpoint,
            connectionID: connectionID,
            snapshotGeneration: generation
        )
    }

    private func ended(endpoint: HerdrSocketEndpoint, connectionID: UUID) async {
        guard await roster.connectionEnded(at: endpoint, connectionID: connectionID) else { return }
        guard let generation = lifecycleGeneration else { return }
        await scheduleReconnect(reason: "Herdr event stream disconnected.", generation: generation)
    }

    private func subscriptionChanged(
        _ groups: [AgentGroup],
        at endpoint: HerdrSocketEndpoint,
        connectionID: UUID
    ) async {
        guard await roster.applySubscriptionChange(
            groups,
            at: endpoint,
            connectionID: connectionID
        ) else { return }
        guard let generation = lifecycleGeneration else { return }
        scheduleDiscovery(after: .milliseconds(50), generation: generation)
    }

    private func scheduleReconnect(reason: String, generation: UInt64) async {
        guard await roster.isActive(generation) else { return }
        guard !immediateRetryRequested else { return }
        reconnectAttempt += 1
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        await roster.publishUnavailable(reason: reason, retryAt: now().addingTimeInterval(delay))
        scheduleDiscovery(after: .seconds(delay), generation: generation)
    }

    nonisolated static func safeDiagnostic(_ message: String) -> String {
        let message = message.lowercased()
        if message.contains("permission denied") || message.contains("authentication failed") {
            return "SSH authentication failed."
        }
        if message.contains("host key verification failed") || message.contains("remote host identification has changed") {
            return "SSH host key verification failed."
        }
        if message.contains("could not resolve hostname") {
            return "SSH host could not be resolved."
        }
        if message.contains("connection refused") {
            return "SSH connection was refused."
        }
        if message.contains("no route to host") || message.contains("network is unreachable") {
            return "SSH host is unreachable."
        }
        if message.contains("timed out") || message.contains("timeout") {
            return "SSH connection timed out."
        }
        if message.contains("herdr") && message.contains("not found") {
            return "Herdr was not found in remote login shell."
        }
        if message.contains("herdr is not installed") {
            return "Herdr is not installed on this Mac."
        }
        return "SSH command failed."
    }

    private nonisolated static func safeStreamDiagnostic(_ message: String?) -> String {
        guard let message else { return "Herdr event stream could not start." }
        let classified = safeDiagnostic(message)
        if classified != "SSH command failed." { return classified }
        let normalized = message.lowercased()
        if normalized.contains("nc")
            && (normalized.contains("not found") || normalized.contains("invalid option"))
        {
            return "Remote nc lacks Unix socket support."
        }
        return "Herdr event stream could not start."
    }

    private func scheduleDiscovery(after delay: Duration, generation: UInt64) {
        guard lifecycleGeneration == generation else { return }
        discoveryScheduleGeneration &+= 1
        let scheduleGeneration = discoveryScheduleGeneration
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard let self else { return }
            await self.discoveryDidFire(
                generation: generation,
                scheduleGeneration: scheduleGeneration
            )
        }
    }

    private func discoveryDidFire(generation: UInt64, scheduleGeneration: UInt64) async {
        guard lifecycleGeneration == generation,
              discoveryScheduleGeneration == scheduleGeneration
        else { return }
        discoveryTask = nil
        await discover(generation: generation)
    }
}
