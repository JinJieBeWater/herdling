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
    case unavailable(reason: String? = nil, retryAt: Date? = nil)
}

protocol SessionMonitoring: Sendable {
    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async
    func stop() async
    func retry() async
}

extension SessionMonitoring {
    func retry() async {}
}

actor HerdrLocalSessionMonitor: SessionMonitoring {
    private let configDirectory: URL
    private let roster = HerdrSocketRoster()
    private var discoveryTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64?

    init(configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr")) {
        self.configDirectory = configDirectory
    }

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        guard lifecycleGeneration == nil else { return }
        let generation = await roster.start(handler: handler)
        lifecycleGeneration = generation
        await discover(generation: generation)
        guard await roster.isActive(generation) else { return }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                await self?.discover(generation: generation)
            }
        }
    }

    func stop() async {
        lifecycleGeneration = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        await roster.stop()
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
        guard await roster.isActive(generation) else { return }
        let endpoints = Self.endpoints(configDirectory: configDirectory)
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
            let connection = makeConnection(endpoint)
            await roster.addConnection(connection, for: endpoint)
            pending.append((endpoint, connection))
        }
        let results = await HerdrSocketConnection.startAll(pending)
        guard await roster.isActive(generation) else { return }
        for result in results where !result.succeeded {
            await roster.removeConnection(at: result.path, connectionID: result.connectionID)
        }
        if topologyChanged || !pending.isEmpty { await roster.publishSessions() }
    }

    private func makeConnection(_ endpoint: HerdrSocketEndpoint) -> HerdrSocketConnection {
        HerdrSocketConnection(
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
        await roster.publishSessions()
        guard let generation = lifecycleGeneration else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            await self?.discover(generation: generation)
        }
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
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await self?.discover(generation: generation)
        }
    }
}

final class HerdrSocketConnection: @unchecked Sendable {
    struct StartResult: Sendable {
        let path: String
        let connectionID: UUID
        let succeeded: Bool
        let failureReason: String?
    }

    let id = UUID()
    private let endpoint: HerdrSocketEndpoint
    private let eventExecutable: String
    private let eventArguments: [String]
    private let loadSnapshot: @Sendable (@Sendable () -> Bool) throws -> [AgentGroup]
    private let onSubscriptionChange: @Sendable (UUID, HerdrSocketEndpoint, [AgentGroup]) -> Void
    private let onSnapshot: @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void
    private let onEnd: @Sendable (UUID, HerdrSocketEndpoint) -> Void
    private let queue = DispatchQueue(label: "dev.herdr.Herdling.socket")
    private let lock = NSLock()
    private let snapshotRequestLock = NSLock()
    private let subscriptionStarted = DispatchSemaphore(value: 0)
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
    private var finished = false
    private var stopped = false

    init(
        endpoint: HerdrSocketEndpoint,
        eventExecutable: String? = nil,
        eventArguments: [String]? = nil,
        loadSnapshot: (@Sendable () throws -> [AgentGroup])? = nil,
        onSubscriptionChange: @escaping @Sendable (UUID, HerdrSocketEndpoint, [AgentGroup]) -> Void = { _, _, _ in },
        onSnapshot: @escaping @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void,
        onEnd: @escaping @Sendable (UUID, HerdrSocketEndpoint) -> Void
    ) {
        let executable = eventExecutable ?? "/usr/bin/nc"
        let arguments = eventArguments ?? ["-U", endpoint.path]
        self.endpoint = endpoint
        self.eventExecutable = executable
        self.eventArguments = arguments
        if let loadSnapshot {
            self.loadSnapshot = { _ in try loadSnapshot() }
        } else {
            self.loadSnapshot = { isCancelled in
                let request = HerdrLocalSessionMonitor.snapshotRequest(id: "snapshot-\(UUID().uuidString)") + "\n"
                let data = try CommandRunner.run(
                    executable,
                    arguments,
                    timeout: 7,
                    standardInput: Data(request.utf8),
                    isCancelled: isCancelled
                )
                return try HerdrClient.parseGroups(data)
            }
        }
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
                            succeeded: true,
                            failureReason: nil
                        )
                    } catch {
                        connection.stop()
                        return StartResult(
                            path: endpoint.path,
                            connectionID: connection.id,
                            succeeded: false,
                            failureReason: error.localizedDescription
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
                        succeeded: succeeded,
                        failureReason: succeeded ? nil : "Herdr snapshot refresh failed."
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
    }

    func start() throws {
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        let preliminaryGroups = try requestSnapshot()
        let paneIDs = Set(preliminaryGroups.flatMap(\.agents).map(\.paneID))
        queue.sync {
            groups = preliminaryGroups
            subscribedPaneIDs = paneIDs
        }

        try launchTransport()

        try send(HerdrLocalSessionMonitor.subscriptionRequest(paneIDs: paneIDs))
        guard subscriptionStarted.wait(timeout: .now() + 7) == .success else {
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

    /// Spawns the socket transport and registers its handles under the lock. Throws (after
    /// terminating the process) when the connection was stopped midway.
    private func launchTransport() throws {
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
    }

    func stop() {
        let values = lock.withLock { () -> (Process?, FileHandle?) in
            stopped = true
            output?.readabilityHandler = nil
            return (process, input)
        }
        subscriptionStarted.signal()
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
        switch HerdrSocketMessage.decode(line) {
        case let .event(event):
            handle(event)
        case .subscriptionStarted:
            subscriptionStarted.signal()
        case .other:
            break
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
        let response = try loadSnapshot { [weak self] in
            guard let self else { return true }
            return self.lock.withLock { self.stopped }
        }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
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

    // ponytail: one persistent system transport process per session avoids a custom socket client;
    // replace it only if sandboxing or profiling proves the process cost matters.
}
