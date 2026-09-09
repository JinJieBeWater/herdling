import Foundation

/// Connection and snapshot bookkeeping shared by the local and remote session monitors.
///
/// The monitors own discovery and reconnect policy; this actor owns the socket pool, the
/// snapshot ledger, and the serialized publication of `SessionMonitorEvent`s.
actor HerdrSocketRoster {
    private var handler: (@Sendable (SessionMonitorEvent) async -> Void)?
    private var publicationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var connections: [String: HerdrSocketConnection] = [:]
    private var snapshots: [String: HerdrClient.LoadedSession] = [:]
    private var snapshotGenerations = SnapshotGenerationLedger()
    private var endpointOrder: [String] = []
    private var hasDiscovered = false

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) -> UInt64 {
        generation &+= 1
        self.handler = handler
        return generation
    }

    func stop() {
        generation &+= 1
        handler = nil
        publicationTask?.cancel()
        publicationTask = nil
        connections.values.forEach { $0.stop() }
        connections.removeAll()
        snapshots.removeAll()
        snapshotGenerations.removeAll()
        endpointOrder.removeAll()
        hasDiscovered = false
    }

    func isActive(_ generation: UInt64) -> Bool {
        handler != nil && self.generation == generation
    }

    /// Replaces the endpoint order, stops connections whose socket disappeared, and reports topology change.
    func reconcileEndpoints(_ endpoints: [HerdrSocketEndpoint]) -> Bool {
        let nextOrder = endpoints.map(\.path)
        let topologyChanged = !hasDiscovered || endpointOrder != nextOrder
        hasDiscovered = true
        endpointOrder = nextOrder
        let livePaths = Set(nextOrder)
        for path in connections.keys where !livePaths.contains(path) {
            removeConnection(at: path)
        }
        return topologyChanged
    }

    func existingConnections(
        _ endpoints: [HerdrSocketEndpoint]
    ) -> [(HerdrSocketEndpoint, HerdrSocketConnection)] {
        endpoints.compactMap { endpoint in
            connections[endpoint.path].map { (endpoint, $0) }
        }
    }

    func hasConnection(at path: String) -> Bool {
        connections[path] != nil
    }

    func addConnection(_ connection: HerdrSocketConnection, for endpoint: HerdrSocketEndpoint) {
        connections[endpoint.path] = connection
    }

    @discardableResult
    func removeConnection(at path: String, connectionID: UUID? = nil) -> Bool {
        if let connectionID, connections[path]?.id != connectionID { return false }
        connections.removeValue(forKey: path)?.stop()
        snapshots.removeValue(forKey: path)
        snapshotGenerations.remove(endpoint: path)
        return true
    }

    func receive(
        _ groups: [AgentGroup],
        from endpoint: HerdrSocketEndpoint,
        connectionID: UUID,
        snapshotGeneration: UInt64
    ) {
        guard connections[endpoint.path]?.id == connectionID,
              snapshotGenerations.accept(endpoint: endpoint.path, generation: snapshotGeneration)
        else { return }
        snapshots[endpoint.path] = HerdrClient.LoadedSession(name: endpoint.session, groups: groups, error: nil)
        publishSessions()
    }

    func applySubscriptionChange(
        _ groups: [AgentGroup],
        at endpoint: HerdrSocketEndpoint,
        connectionID: UUID
    ) -> Bool {
        guard connections[endpoint.path]?.id == connectionID else { return false }
        snapshots[endpoint.path] = HerdrClient.LoadedSession(
            name: endpoint.session,
            groups: groups,
            error: nil
        )
        publishSessions()
        connections.removeValue(forKey: endpoint.path)?.stop()
        snapshotGenerations.remove(endpoint: endpoint.path)
        return true
    }

    func connectionEnded(at endpoint: HerdrSocketEndpoint, connectionID: UUID) -> Bool {
        guard connections[endpoint.path]?.id == connectionID else { return false }
        connections.removeValue(forKey: endpoint.path)
        snapshots.removeValue(forKey: endpoint.path)
        snapshotGenerations.remove(endpoint: endpoint.path)
        return true
    }

    func publishSessions() {
        guard !endpointOrder.isEmpty,
              endpointOrder.allSatisfy({ connections[$0] != nil && snapshots[$0] != nil })
        else {
            publish(.unavailable())
            return
        }
        publish(.sessions(endpointOrder.compactMap { snapshots[$0] }))
    }

    func publishUnavailable(reason: String? = nil, retryAt: Date? = nil) {
        publish(.unavailable(reason: reason, retryAt: retryAt))
    }

    private func publish(_ event: SessionMonitorEvent) {
        guard let handler else { return }
        let previous = publicationTask
        let current = generation
        publicationTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, await self.isActive(current) else { return }
            await handler(event)
        }
    }
}
