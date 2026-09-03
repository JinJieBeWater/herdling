import Darwin
import Foundation

struct HerdrSocketEndpoint: Equatable, Sendable {
    let session: String
    let path: String
}

struct SnapshotGenerationLedger {
    private var latest: [String: UInt64] = [:]

    mutating func accept(endpoint: String, generation: UInt64) -> Bool {
        guard generation >= latest[endpoint, default: 0] else { return false }
        latest[endpoint] = generation
        return true
    }

    mutating func remove(endpoint: String) {
        latest.removeValue(forKey: endpoint)
    }

    mutating func removeAll() {
        latest.removeAll()
    }
}

enum SessionMonitorEvent: Sendable {
    case sessions([HerdrClient.LoadedSession])
    case unavailable
}

protocol SessionMonitoring: Sendable {
    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async
    func stop() async
}

actor HerdrLocalSessionMonitor: SessionMonitoring {
    private let configDirectory: URL
    private var handler: (@Sendable (SessionMonitorEvent) async -> Void)?
    private var discoveryTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var connections: [String: HerdrSocketConnection] = [:]
    private var snapshots: [String: HerdrClient.LoadedSession] = [:]
    private var snapshotGenerations = SnapshotGenerationLedger()
    private var endpointOrder: [String] = []
    private var hasDiscoveredEndpoints = false
    private var lifecycleGeneration: UInt64 = 0

    init(configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr")) {
        self.configDirectory = configDirectory
    }

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        guard self.handler == nil else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        self.handler = handler
        await discover(generation: generation)
        guard self.handler != nil, lifecycleGeneration == generation else { return }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                await self?.discover(generation: generation)
            }
        }
    }

    func stop() {
        lifecycleGeneration &+= 1
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
        hasDiscoveredEndpoints = false
    }

    static func endpoints(configDirectory: URL) -> [HerdrSocketEndpoint] {
        let manager = FileManager.default
        var result: [HerdrSocketEndpoint] = []
        let defaultSocket = configDirectory.appendingPathComponent("herdr.sock")
        if manager.fileExists(atPath: defaultSocket.path) {
            result.append(HerdrSocketEndpoint(session: "default", path: defaultSocket.path))
        }

        let sessionsDirectory = configDirectory.appendingPathComponent("sessions")
        let names = (try? manager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.map(\.lastPathComponent).sorted() ?? []
        for name in names {
            let socket = sessionsDirectory.appendingPathComponent(name).appendingPathComponent("herdr.sock")
            if manager.fileExists(atPath: socket.path) {
                result.append(HerdrSocketEndpoint(session: name, path: socket.path))
            }
        }
        return result
    }

    static func subscriptionRequest(paneIDs: Set<String>) -> String {
        let topologyTypes = [
            "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
            "workspace.moved", "workspace.reordered", "workspace.closed",
            "worktree.created", "worktree.opened", "worktree.removed",
            "tab.created", "tab.closed", "tab.renamed", "tab.moved",
            "pane.created", "pane.updated", "pane.closed", "pane.moved", "pane.exited",
            "pane.agent_detected",
        ]
        var subscriptions = topologyTypes.map { ["type": $0] }
        subscriptions += paneIDs.sorted().map {
            ["type": "pane.agent_status_changed", "pane_id": $0]
        }
        let object: [String: Any] = [
            "id": "subscription",
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func snapshotRequest(id: String) -> String {
        #"{"id":"\#(id)","method":"session.snapshot","params":{}}"#
    }

    private func discover(generation: UInt64) async {
        guard handler != nil, lifecycleGeneration == generation else { return }
        let endpoints = Self.endpoints(configDirectory: configDirectory)
        let nextEndpointOrder = endpoints.map(\.path)
        let topologyChanged = !hasDiscoveredEndpoints || endpointOrder != nextEndpointOrder
        hasDiscoveredEndpoints = true
        endpointOrder = nextEndpointOrder
        let livePaths = Set(endpointOrder)
        let removedPaths = connections.keys.filter { !livePaths.contains($0) }
        for path in removedPaths {
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
            let connection = HerdrSocketConnection(
                endpoint: endpoint,
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
            connections[endpoint.path] = connection
            pendingConnections.append((endpoint, connection))
        }
        let results = await HerdrSocketConnection.startAll(pendingConnections)
        guard handler != nil, lifecycleGeneration == generation else { return }
        for result in results where !result.succeeded {
            guard connections[result.path]?.id == result.connectionID else { continue }
            connections.removeValue(forKey: result.path)?.stop()
            snapshots.removeValue(forKey: result.path)
            snapshotGenerations.remove(endpoint: result.path)
        }
        if topologyChanged || !pendingConnections.isEmpty { publish() }
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
        publish()
        let generation = lifecycleGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            await self?.discover(generation: generation)
        }
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
        let generation = lifecycleGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.discover(generation: generation)
        }
    }

    private func publish() {
        guard let handler else { return }
        let event: SessionMonitorEvent
        guard !endpointOrder.isEmpty,
              endpointOrder.allSatisfy({ connections[$0] != nil && snapshots[$0] != nil })
        else {
            event = .unavailable
            enqueue(event, handler: handler)
            return
        }
        event = .sessions(endpointOrder.compactMap { snapshots[$0] })
        enqueue(event, handler: handler)
    }

    private func enqueue(
        _ event: SessionMonitorEvent,
        handler: @escaping @Sendable (SessionMonitorEvent) async -> Void
    ) {
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
}

final class HerdrSocketConnection: @unchecked Sendable {
    struct StartResult: Sendable {
        let path: String
        let connectionID: UUID
        let succeeded: Bool
    }

    let id = UUID()
    private let endpoint: HerdrSocketEndpoint
    private let eventExecutable: String
    private let eventArguments: [String]
    private let onSubscriptionChange: @Sendable (UUID, HerdrSocketEndpoint, [AgentGroup]) -> Void
    private let onSnapshot: @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void
    private let onEnd: @Sendable (UUID, HerdrSocketEndpoint) -> Void
    private let queue = DispatchQueue(label: "dev.herdr.Herdling.socket")
    private let lock = NSLock()
    private let snapshotRequestLock = NSLock()
    private let snapshotResponseLock = NSLock()
    private let subscriptionStarted = DispatchSemaphore(value: 0)
    private let snapshotReceived = DispatchSemaphore(value: 0)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var snapshotGeneration: UInt64 = 0
    private var groups: [AgentGroup] = []
    private var pendingEvents: [HerdrSocketEvent] = []
    private var bootstrapComplete = false
    private var resyncPending = false
    private var resyncInFlight = false
    private var resyncScheduleGeneration: UInt64 = 0
    private var subscribedPaneIDs: Set<String> = []
    private var snapshotRequestSequence: UInt64 = 0
    private var awaitingSnapshotID: String?
    private var snapshotResponse: [AgentGroup]?
    private var finished = false
    private var stopped = false

    init(
        endpoint: HerdrSocketEndpoint,
        eventExecutable: String? = nil,
        eventArguments: [String]? = nil,
        onSubscriptionChange: @escaping @Sendable (UUID, HerdrSocketEndpoint, [AgentGroup]) -> Void = { _, _, _ in },
        onSnapshot: @escaping @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void,
        onEnd: @escaping @Sendable (UUID, HerdrSocketEndpoint) -> Void
    ) {
        self.endpoint = endpoint
        self.eventExecutable = eventExecutable ?? "/usr/bin/nc"
        self.eventArguments = eventArguments ?? ["-U", endpoint.path]
        self.onSubscriptionChange = onSubscriptionChange
        self.onSnapshot = onSnapshot
        self.onEnd = onEnd
    }

    static func startAll(
        _ pending: [(HerdrSocketEndpoint, HerdrSocketConnection)]
    ) async -> [StartResult] {
        await withTaskGroup(of: StartResult.self, returning: [StartResult].self) { group in
            for (endpoint, connection) in pending {
                group.addTask {
                    do {
                        try connection.start()
                        return StartResult(
                            path: endpoint.path,
                            connectionID: connection.id,
                            succeeded: true
                        )
                    } catch {
                        connection.stop()
                        return StartResult(
                            path: endpoint.path,
                            connectionID: connection.id,
                            succeeded: false
                        )
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    static func refreshAll(
        _ connections: [(HerdrSocketEndpoint, HerdrSocketConnection)]
    ) async -> [StartResult] {
        await withTaskGroup(of: StartResult.self, returning: [StartResult].self) { group in
            for (endpoint, connection) in connections {
                group.addTask {
                    let succeeded = (try? connection.refresh()) == true
                    return StartResult(
                        path: endpoint.path,
                        connectionID: connection.id,
                        succeeded: succeeded
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    func start() throws {
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: eventExecutable)
        process.arguments = eventArguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.finish() }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { self.finish(); return }
            self.queue.async { self.consume(data) }
        }
        let canStart = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            self.process = process
            input = inputPipe.fileHandleForWriting
            output = outputPipe.fileHandleForReading
            return true
        }
        guard canStart else { throw CancellationError() }
        try process.run()
        guard !lock.withLock({ stopped }) else {
            process.terminate()
            throw CancellationError()
        }

        let preliminaryGroups = try requestSnapshot()
        let paneIDs = Set(preliminaryGroups.flatMap(\.agents).map(\.paneID))
        queue.sync {
            groups = preliminaryGroups
            subscribedPaneIDs = paneIDs
        }
        try send(HerdrLocalSessionMonitor.subscriptionRequest(paneIDs: paneIDs))
        guard subscriptionStarted.wait(timeout: .now() + 3) == .success else {
            throw CommandRunner.Error.timedOut
        }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }

        let authoritativeGroups = try requestSnapshot()
        let authoritativePaneIDs = Set(authoritativeGroups.flatMap(\.agents).map(\.paneID))
        var bootstrapSucceeded = false
        queue.sync {
            groups = authoritativeGroups
            guard authoritativePaneIDs == subscribedPaneIDs else { return }
            var needsResync = false
            for event in pendingEvents where !shouldIgnore(event) {
                switch event {
                case .paneClosed, .tabClosed:
                    _ = apply(event)
                    needsResync = true
                case .resyncRequired:
                    needsResync = true
                case .agentStatusChanged, .paneUpdated:
                    if !apply(event) { needsResync = true }
                }
            }
            pendingEvents.removeAll()
            bootstrapSucceeded = true
            bootstrapComplete = true
            publish(groups)
            if needsResync { scheduleResync() }
        }
        guard bootstrapSucceeded else {
            throw CommandRunner.Error.failed("Herdr subscription changed during startup.")
        }
    }

    func stop() {
        let values = lock.withLock { () -> (Process?, FileHandle?) in
            stopped = true
            output?.readabilityHandler = nil
            return (process, input)
        }
        subscriptionStarted.signal()
        snapshotReceived.signal()
        try? values.1?.close()
        if let process = values.0, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        queue.async { [weak self] in
            guard let self else { return }
            resyncScheduleGeneration &+= 1
            resyncPending = false
        }
    }

    func refresh() throws -> Bool {
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        let mutationAtStart = queue.sync { snapshotGeneration }
        let refreshedGroups = try requestSnapshot()
        let paneIDs = Set(refreshedGroups.flatMap(\.agents).map(\.paneID))
        var subscriptionStillValid = false
        queue.sync {
            subscriptionStillValid = paneIDs == subscribedPaneIDs
            guard subscriptionStillValid, mutationAtStart == snapshotGeneration else { return }
            groups = refreshedGroups
            publish(groups)
        }
        return subscriptionStillValid
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty else { return }
        do {
            switch try HerdrSocketMessage.decode(line, refreshedAt: .now) {
            case let .event(event):
                handle(event)
            case .subscriptionStarted:
                subscriptionStarted.signal()
            case let .snapshot(id: responseID, groups: groups):
                let shouldSignal = snapshotResponseLock.withLock { () -> Bool in
                    guard responseID == awaitingSnapshotID else { return false }
                    snapshotResponse = groups
                    awaitingSnapshotID = nil
                    return true
                }
                if shouldSignal { snapshotReceived.signal() }
            case .other:
                break
            }
        } catch {
            // A malformed line must not tear down an otherwise healthy event stream.
        }
    }

    private func handle(_ event: HerdrSocketEvent) {
        guard !lock.withLock({ stopped }) else { return }
        guard bootstrapComplete else {
            pendingEvents.append(event)
            return
        }
        guard !shouldIgnore(event) else { return }
        if case let .paneClosed(paneID, workspaceID) = event {
            if removeAgent(paneID: paneID, workspaceID: workspaceID) { publish(groups) }
            scheduleResync()
            return
        }
        if case let .tabClosed(tabID, workspaceID) = event {
            if removeAgents(tabID: tabID, workspaceID: workspaceID) { publish(groups) }
            scheduleResync()
            return
        }
        if case .resyncRequired = event {
            scheduleResync()
        } else if apply(event) {
            publish(groups)
        } else {
            scheduleResync()
        }
    }

    private func apply(_ event: HerdrSocketEvent) -> Bool {
        switch event {
        case .resyncRequired:
            return false
        case let .paneClosed(paneID, workspaceID):
            _ = removeAgent(paneID: paneID, workspaceID: workspaceID)
            return true
        case let .tabClosed(tabID, workspaceID):
            _ = removeAgents(tabID: tabID, workspaceID: workspaceID)
            return true
        case let .agentStatusChanged(data):
            return updateAgent(data, fullPane: false)
        case let .paneUpdated(data):
            return updateAgent(data, fullPane: true)
        }
    }

    private func shouldIgnore(_ event: HerdrSocketEvent) -> Bool {
        guard case let .paneUpdated(data) = event,
              let paneID = data.paneID,
              let revision = data.revision,
              let currentRevision = groups.lazy.flatMap(\.agents).first(where: { $0.paneID == paneID })?.revision
        else { return false }
        return revision <= currentRevision
    }

    private func scheduleResync(delay: TimeInterval = 0.2) {
        guard !lock.withLock({ stopped }) else { return }
        resyncPending = true
        guard !resyncInFlight else { return }
        resyncScheduleGeneration &+= 1
        let generation = resyncScheduleGeneration
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.beginResync(generation: generation)
        }
    }

    private func beginResync(generation: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  generation == resyncScheduleGeneration,
                  resyncPending,
                  !resyncInFlight,
                  !lock.withLock({ stopped })
            else { return }
            resyncPending = false
            resyncInFlight = true
            let mutationAtStart = snapshotGeneration
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let result = Result { try requestSnapshot() }
                queue.async { [weak self] in
                    self?.finishResync(result, mutationAtStart: mutationAtStart)
                }
            }
        }
    }

    private func finishResync(
        _ result: Result<[AgentGroup], Error>,
        mutationAtStart: UInt64
    ) {
        resyncInFlight = false
        guard !lock.withLock({ stopped }) else { return }
        if case let .success(refreshedGroups) = result {
            if mutationAtStart == snapshotGeneration {
                groups = refreshedGroups
                let paneIDs = Set(groups.flatMap(\.agents).map(\.paneID))
                if paneIDs == subscribedPaneIDs {
                    publish(groups)
                } else {
                    onSubscriptionChange(id, endpoint, groups)
                    return
                }
            } else {
                resyncPending = true
            }
        }
        if resyncPending { scheduleResync(delay: 0.05) }
    }

    private func removeAgent(paneID: String, workspaceID: String?) -> Bool {
        let candidateIndices = groups.indices.filter { workspaceID == nil || groups[$0].id == workspaceID }
        for groupIndex in candidateIndices {
            guard let agentIndex = groups[groupIndex].agents.firstIndex(where: { $0.paneID == paneID }) else {
                continue
            }
            groups[groupIndex].agents.remove(at: agentIndex)
            return true
        }
        return false
    }

    private func removeAgents(tabID: String, workspaceID: String?) -> Bool {
        var removed = false
        for groupIndex in groups.indices where workspaceID == nil || groups[groupIndex].id == workspaceID {
            let originalCount = groups[groupIndex].agents.count
            groups[groupIndex].agents.removeAll { $0.tabID == tabID }
            removed = removed || groups[groupIndex].agents.count != originalCount
        }
        return removed
    }

    private func updateAgent(_ data: EventData, fullPane: Bool) -> Bool {
        guard let paneID = data.paneID,
              let workspaceID = data.workspaceID,
              let groupIndex = groups.firstIndex(where: { $0.id == workspaceID }),
              let agentIndex = groups[groupIndex].agents.firstIndex(where: { $0.paneID == paneID })
        else { return false }
        let current = groups[groupIndex].agents[agentIndex]
        let status = data.agentStatus.flatMap(AgentStatus.init(rawValue:)) ?? current.status
        let title = data.label
            ?? data.displayAgent
            ?? data.title
            ?? data.terminalTitleStripped
            ?? data.terminalTitle
            ?? data.agent
            ?? current.title
        let cwd = fullPane ? (data.foregroundCWD ?? data.cwd ?? current.cwd) : current.cwd
        groups[groupIndex].agents[agentIndex] = AgentInfo(
            paneID: current.paneID,
            tabID: fullPane ? (data.tabID ?? current.tabID) : current.tabID,
            title: title,
            status: status,
            workspace: groups[groupIndex].name,
            cwd: cwd,
            revision: fullPane ? (data.revision ?? current.revision) : current.revision,
            updatedAt: .now
        )
        return true
    }

    private func requestSnapshot() throws -> [AgentGroup] {
        snapshotRequestLock.lock()
        defer { snapshotRequestLock.unlock() }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        while snapshotReceived.wait(timeout: .now()) == .success {}
        snapshotRequestSequence &+= 1
        let requestID = "snapshot-\(id.uuidString)-\(snapshotRequestSequence)"
        snapshotResponseLock.withLock {
            awaitingSnapshotID = requestID
            snapshotResponse = nil
        }
        defer {
            snapshotResponseLock.withLock {
                awaitingSnapshotID = nil
                snapshotResponse = nil
            }
        }
        try send(HerdrLocalSessionMonitor.snapshotRequest(id: requestID))
        guard snapshotReceived.wait(timeout: .now() + 3) == .success else {
            throw CommandRunner.Error.timedOut
        }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        guard let response = snapshotResponseLock.withLock({ snapshotResponse }) else {
            throw CommandRunner.Error.failed("Herdr snapshot response is missing.")
        }
        return response
    }

    private func publish(_ groups: [AgentGroup]) {
        snapshotGeneration &+= 1
        onSnapshot(id, endpoint, snapshotGeneration, groups)
    }

    private func send(_ request: String) throws {
        guard let data = (request + "\n").data(using: .utf8) else { return }
        let handle = lock.withLock { input }
        guard let handle else { throw CommandRunner.Error.failed("Herdr socket is closed.") }
        try handle.write(contentsOf: data)
    }

    private func finish() {
        let shouldNotify = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            output?.readabilityHandler = nil
            process = nil
            input = nil
            output = nil
            return !stopped
        }
        if shouldNotify { onEnd(id, endpoint) }
    }

    private func fail() {
        let process = lock.withLock { self.process }
        if process?.isRunning == true { process?.terminate() }
        finish()
    }

    // ponytail: one persistent system transport process per session avoids a custom socket client;
    // replace it only if sandboxing or profiling proves the process cost matters.
}
