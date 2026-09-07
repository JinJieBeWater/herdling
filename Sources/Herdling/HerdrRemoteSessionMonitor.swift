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
    private var handler: (@Sendable (SessionMonitorEvent) async -> Void)?
    private var discoveryTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var connections: [String: HerdrSocketConnection] = [:]
    private var snapshots: [String: HerdrClient.LoadedSession] = [:]
    private var snapshotGenerations = SnapshotGenerationLedger()
    private var endpointOrder: [String] = []
    private var hasDiscoveredSessions = false
    private var reconnectAttempt = 0
    private var isDiscovering = false
    private var immediateRetryRequested = false
    private var lifecycleGeneration: UInt64 = 0
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
        guard self.handler == nil else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        self.handler = handler
        await discover(generation: generation)
    }

    func stop() {
        lifecycleGeneration &+= 1
        discoveryScheduleGeneration &+= 1
        handler = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        publicationTask?.cancel()
        publicationTask = nil
        connections.values.forEach { $0.stop() }
        connections.removeAll()
        snapshots.removeAll()
        snapshotGenerations.removeAll()
        endpointOrder.removeAll()
        hasDiscoveredSessions = false
        reconnectAttempt = 0
        isDiscovering = false
        immediateRetryRequested = false
    }

    static func socketCommand(path: String) -> String {
        "exec nc -U \(HerdrClient.shellQuote(path))"
    }

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(attempt, 1) - 1)), 60)
    }

    var isDiscoveryScheduled: Bool { discoveryTask != nil }

    func retry() async {
        guard handler != nil else { return }
        discoveryScheduleGeneration &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        guard !isDiscovering else {
            immediateRetryRequested = true
            return
        }
        await discover(generation: lifecycleGeneration)
    }

    private func discover(generation: UInt64) async {
        guard handler != nil, lifecycleGeneration == generation, !isDiscovering else { return }
        isDiscovering = true
        defer {
            isDiscovering = false
            if immediateRetryRequested, handler != nil, lifecycleGeneration == generation {
                immediateRetryRequested = false
                scheduleDiscovery(after: .zero, generation: generation)
            }
        }
        let result = await discoverSessions()
        guard handler != nil, lifecycleGeneration == generation else { return }
        guard case let .sessions(sessions) = result else {
            let reason = if case let .failure(message) = result {
                Self.safeDiagnostic(message)
            } else {
                "SSH command failed."
            }
            scheduleReconnect(reason: reason, generation: generation)
            return
        }

        let endpoints = sessions.map {
            HerdrSocketEndpoint(session: $0.name, path: $0.socketPath)
        }
        let nextEndpointOrder = endpoints.map(\.path)
        let topologyChanged = !hasDiscoveredSessions || endpointOrder != nextEndpointOrder
        hasDiscoveredSessions = true
        endpointOrder = nextEndpointOrder
        let livePaths = Set(endpointOrder)
        for path in connections.keys where !livePaths.contains(path) {
            removeConnection(at: path)
        }
        let existingConnections = endpoints.compactMap { endpoint in
            connections[endpoint.path].map { (endpoint, $0) }
        }
        let refreshResults = await HerdrSocketConnection.refreshAll(existingConnections)
        guard handler != nil, lifecycleGeneration == generation else { return }
        for result in refreshResults where !result.succeeded {
            guard connections[result.path]?.id == result.connectionID else { continue }
            removeConnection(at: result.path)
        }
        var pendingConnections: [(HerdrSocketEndpoint, HerdrSocketConnection)] = []
        for endpoint in endpoints where connections[endpoint.path] == nil {
            guard let connection = makeConnection(endpoint) else { continue }
            connections[endpoint.path] = connection
            pendingConnections.append((endpoint, connection))
        }
        let failure = await startConnections(pendingConnections, generation: generation)
        guard handler != nil, lifecycleGeneration == generation else { return }
        if topologyChanged || !pendingConnections.isEmpty { publish() }
        if let failure {
            scheduleReconnect(reason: failure, generation: generation)
        } else {
            reconnectAttempt = 0
            scheduleDiscovery(after: Self.discoveryInterval, generation: generation)
        }
    }

    private func removeConnection(at path: String) {
        connections.removeValue(forKey: path)?.stop()
        snapshots.removeValue(forKey: path)
        snapshotGenerations.remove(endpoint: path)
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
            guard handler != nil, lifecycleGeneration == generation else { continue }
            guard connections[result.path]?.id == result.connectionID else { continue }
            guard result.succeeded else {
                failure = failure ?? Self.safeStreamDiagnostic(result.failureReason)
                removeConnection(at: result.path)
                continue
            }
        }

        return failure
    }

    private func received(
        _ groups: [AgentGroup],
        from endpoint: HerdrSocketEndpoint,
        connectionID: UUID,
        generation: UInt64
    ) {
        guard connections[endpoint.path]?.id == connectionID,
              snapshotGenerations.accept(endpoint: endpoint.path, generation: generation)
        else { return }
        snapshots[endpoint.path] = HerdrClient.LoadedSession(name: endpoint.session, groups: groups, error: nil)
        publish()
    }

    private func ended(endpoint: HerdrSocketEndpoint, connectionID: UUID) {
        guard connections[endpoint.path]?.id == connectionID else { return }
        connections.removeValue(forKey: endpoint.path)
        snapshots.removeValue(forKey: endpoint.path)
        snapshotGenerations.remove(endpoint: endpoint.path)
        scheduleReconnect(reason: "Herdr event stream disconnected.", generation: lifecycleGeneration)
    }

    private func subscriptionChanged(
        _ groups: [AgentGroup],
        at endpoint: HerdrSocketEndpoint,
        connectionID: UUID
    ) {
        guard connections[endpoint.path]?.id == connectionID else { return }
        snapshots[endpoint.path] = HerdrClient.LoadedSession(
            name: endpoint.session,
            groups: groups,
            error: nil
        )
        publish()
        connections.removeValue(forKey: endpoint.path)?.stop()
        snapshotGenerations.remove(endpoint: endpoint.path)
        scheduleDiscovery(after: .milliseconds(50), generation: lifecycleGeneration)
    }

    private func publish() {
        guard !endpointOrder.isEmpty,
              endpointOrder.allSatisfy({ connections[$0] != nil && snapshots[$0] != nil })
        else {
            publishUnavailable()
            return
        }
        enqueue(.sessions(endpointOrder.compactMap { snapshots[$0] }))
    }

    private func publishUnavailable(reason: String? = nil, retryAt: Date? = nil) {
        enqueue(.unavailable(reason: reason, retryAt: retryAt))
    }

    private func enqueue(_ event: SessionMonitorEvent) {
        guard let handler else { return }
        let previous = publicationTask
        let generation = lifecycleGeneration
        publicationTask = Task { [weak self] in
            await self?.deliver(event, to: handler, after: previous, generation: generation)
        }
    }

    private func deliver(
        _ event: SessionMonitorEvent,
        to handler: @escaping @Sendable (SessionMonitorEvent) async -> Void,
        after previous: Task<Void, Never>?,
        generation: UInt64
    ) async {
        await previous?.value
        guard !Task.isCancelled,
              lifecycleGeneration == generation,
              self.handler != nil
        else { return }
        await handler(event)
    }

    private func scheduleReconnect(reason: String, generation: UInt64) {
        guard handler != nil, lifecycleGeneration == generation else { return }
        guard !immediateRetryRequested else { return }
        reconnectAttempt += 1
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        publishUnavailable(reason: reason, retryAt: now().addingTimeInterval(delay))
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
        guard handler != nil, lifecycleGeneration == generation else { return }
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
        guard handler != nil,
              lifecycleGeneration == generation,
              discoveryScheduleGeneration == scheduleGeneration
        else { return }
        discoveryTask = nil
        await discover(generation: generation)
    }
}
