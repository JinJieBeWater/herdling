import Foundation

actor HerdrRemoteSessionMonitor: SessionMonitoring {
    static let discoveryInterval: Duration = .seconds(60)

    private let source: SourceDescriptor
    private let discoverSessions: @Sendable () async -> [HerdrClient.RunningSession]?
    private var handler: (@Sendable (SessionMonitorEvent) async -> Void)?
    private var discoveryTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var connections: [String: HerdrSocketConnection] = [:]
    private var snapshots: [String: HerdrClient.LoadedSession] = [:]
    private var snapshotGenerations = SnapshotGenerationLedger()
    private var endpointOrder: [String] = []
    private var hasDiscoveredSessions = false
    private var reconnectAttempt = 0
    private var lifecycleGeneration: UInt64 = 0
    private var discoveryScheduleGeneration: UInt64 = 0

    init(
        source: SourceDescriptor,
        client: HerdrClient = HerdrClient(),
        discoverSessions: (@Sendable () async -> [HerdrClient.RunningSession]?)? = nil
    ) {
        precondition(source.sshAlias != nil)
        self.source = source
        self.discoverSessions = discoverSessions ?? {
            await Task.detached { try? client.runningSessions(source) }.value
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
    }

    static func socketCommand(path: String) -> String {
        "exec nc -U \(HerdrClient.shellQuote(path))"
    }

    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(attempt, 1) - 1)), 60)
    }

    var isDiscoveryScheduled: Bool { discoveryTask != nil }

    private func discover(generation: UInt64) async {
        guard handler != nil, lifecycleGeneration == generation else { return }
        let sessions = await discoverSessions()
        guard handler != nil, lifecycleGeneration == generation else { return }
        guard let sessions else {
            publishUnavailable()
            scheduleReconnect(generation: generation)
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
            connections.removeValue(forKey: path)?.stop()
            snapshots.removeValue(forKey: path)
            snapshotGenerations.remove(endpoint: path)
        }
        let existingConnections = endpoints.compactMap { endpoint in
            connections[endpoint.path].map { (endpoint, $0) }
        }
        let refreshResults = await HerdrSocketConnection.refreshAll(existingConnections)
        guard handler != nil, lifecycleGeneration == generation else { return }
        for result in refreshResults where !result.succeeded {
            guard connections[result.path]?.id == result.connectionID else { continue }
            connections.removeValue(forKey: result.path)?.stop()
            snapshots.removeValue(forKey: result.path)
            snapshotGenerations.remove(endpoint: result.path)
        }
        var pendingConnections: [(HerdrSocketEndpoint, HerdrSocketConnection)] = []
        for endpoint in endpoints where connections[endpoint.path] == nil {
            guard let connection = makeConnection(endpoint) else { continue }
            connections[endpoint.path] = connection
            pendingConnections.append((endpoint, connection))
        }
        let failed = await startConnections(pendingConnections, generation: generation)
        guard handler != nil, lifecycleGeneration == generation else { return }
        if topologyChanged || !pendingConnections.isEmpty { publish() }
        if failed {
            scheduleReconnect(generation: generation)
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
    ) async -> Bool {
        guard !pending.isEmpty else { return false }
        var failed = false
        let results = await HerdrSocketConnection.startAll(pending)
        for result in results {
            guard handler != nil, lifecycleGeneration == generation else { continue }
            guard connections[result.path]?.id == result.connectionID else { continue }
            guard result.succeeded else {
                failed = true
                connections.removeValue(forKey: result.path)?.stop()
                snapshots.removeValue(forKey: result.path)
                snapshotGenerations.remove(endpoint: result.path)
                continue
            }
        }

        return failed
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
        publishUnavailable()
        scheduleReconnect(generation: lifecycleGeneration)
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

    private func publishUnavailable() {
        enqueue(.unavailable)
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

    private func scheduleReconnect(generation: UInt64) {
        guard handler != nil, lifecycleGeneration == generation else { return }
        reconnectAttempt += 1
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        scheduleDiscovery(after: .seconds(delay), generation: generation)
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
