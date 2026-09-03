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

    init(configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr")) {
        self.configDirectory = configDirectory
    }

    func start(handler: @escaping @Sendable (SessionMonitorEvent) async -> Void) async {
        guard self.handler == nil else { return }
        self.handler = handler
        await discover()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                await self?.discover()
            }
        }
    }

    func stop() {
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
        let types = [
            "workspace.created", "workspace.updated", "workspace.metadata_updated",
            "workspace.renamed", "workspace.moved", "workspace.reordered", "workspace.closed",
            "worktree.created", "worktree.opened", "worktree.removed",
            "tab.created", "tab.closed", "tab.renamed", "tab.moved",
            "pane.created", "pane.updated", "pane.closed", "pane.moved", "pane.exited",
            "pane.agent_detected",
        ]
        var subscriptions = types.map { ["type": $0] }
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

    static let snapshotRequest = #"{"id":"snapshot","method":"session.snapshot","params":{}}"#

    private func discover() async {
        guard handler != nil else { return }
        let endpoints = Self.endpoints(configDirectory: configDirectory)
        endpointOrder = endpoints.map(\.path)
        let livePaths = Set(endpointOrder)
        let removedPaths = connections.keys.filter { !livePaths.contains($0) }
        for path in removedPaths {
            connections.removeValue(forKey: path)?.stop()
            snapshots.removeValue(forKey: path)
            snapshotGenerations.remove(endpoint: path)
        }
        var pendingConnections: [(HerdrSocketEndpoint, HerdrSocketConnection)] = []
        for endpoint in endpoints where connections[endpoint.path] == nil {
            let connection = HerdrSocketConnection(
                endpoint: endpoint,
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
        guard handler != nil else { return }
        for result in results where !result.succeeded {
            guard connections[result.path]?.id == result.connectionID else { continue }
            connections.removeValue(forKey: result.path)?.stop()
            snapshots.removeValue(forKey: result.path)
            snapshotGenerations.remove(endpoint: result.path)
        }
        publish()
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
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            await self?.discover()
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
        publicationTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await handler(event)
        }
    }
}

final class HerdrSocketConnection: @unchecked Sendable {
    private enum BootstrapStage {
        case preliminary
        case subscribing
        case authoritative
        case complete
    }

    struct StartResult: Sendable {
        let path: String
        let connectionID: UUID
        let succeeded: Bool
    }

    let id = UUID()
    private let endpoint: HerdrSocketEndpoint
    private let eventExecutable: String
    private let eventArguments: [String]
    private let onSnapshot: @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void
    private let onEnd: @Sendable (UUID, HerdrSocketEndpoint) -> Void
    private let queue = DispatchQueue(label: "dev.herdr.Herdling.socket")
    private let lock = NSLock()
    private let subscriptionStarted = DispatchSemaphore(value: 0)
    private let initialSnapshotReceived = DispatchSemaphore(value: 0)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var snapshotWorkItem: DispatchWorkItem?
    private var snapshotRefreshPending = false
    private var snapshotRequestInFlight = false
    private var bootstrapStage = BootstrapStage.preliminary
    private var initialSnapshotSucceeded = false
    private var snapshotGeneration: UInt64 = 0
    private var subscribedPaneIDs: Set<String> = []
    private var finished = false
    private var stopped = false

    init(
        endpoint: HerdrSocketEndpoint,
        eventExecutable: String? = nil,
        eventArguments: [String]? = nil,
        onSnapshot: @escaping @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void,
        onEnd: @escaping @Sendable (UUID, HerdrSocketEndpoint) -> Void
    ) {
        self.endpoint = endpoint
        self.eventExecutable = eventExecutable ?? "/usr/bin/nc"
        self.eventArguments = eventArguments ?? ["-U", endpoint.path]
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

        queue.sync { snapshotRequestInFlight = true }
        try send(HerdrLocalSessionMonitor.snapshotRequest)
        guard initialSnapshotReceived.wait(timeout: .now() + 3) == .success else {
            throw CommandRunner.Error.timedOut
        }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }

        let paneIDs = lock.withLock { subscribedPaneIDs }
        try send(HerdrLocalSessionMonitor.subscriptionRequest(paneIDs: paneIDs))
        guard subscriptionStarted.wait(timeout: .now() + 3) == .success else {
            throw CommandRunner.Error.timedOut
        }
        guard !lock.withLock({ stopped }) else { throw CancellationError() }

        lock.withLock { bootstrapStage = .authoritative }
        queue.sync { snapshotRequestInFlight = true }
        try send(HerdrLocalSessionMonitor.snapshotRequest)
        guard initialSnapshotReceived.wait(timeout: .now() + 3) == .success else {
            throw CommandRunner.Error.timedOut
        }
        guard lock.withLock({ initialSnapshotSucceeded }) else {
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
        initialSnapshotReceived.signal()
        try? values.1?.close()
        if values.0?.isRunning == true { values.0?.terminate() }
        queue.async { [weak self] in
            self?.snapshotWorkItem?.cancel()
            self?.snapshotWorkItem = nil
            self?.snapshotRefreshPending = false
            self?.snapshotRequestInFlight = false
        }
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
            case .event:
                scheduleSnapshot(delay: 0.05)
            case .subscriptionStarted:
                subscriptionStarted.signal()
            case let .snapshot(groups):
                receivedSnapshot(groups)
            case .other:
                break
            }
        } catch {
            // A malformed line must not tear down an otherwise healthy event stream.
        }
    }

    private func scheduleSnapshot(delay: TimeInterval) {
        guard !lock.withLock({ stopped }) else { return }
        snapshotRefreshPending = true
        guard !snapshotRequestInFlight, snapshotWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in self?.requestSnapshot() }
        snapshotWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func requestSnapshot() {
        snapshotWorkItem = nil
        guard !lock.withLock({ stopped }) else {
            snapshotRefreshPending = false
            return
        }
        guard snapshotRefreshPending, !snapshotRequestInFlight else { return }
        snapshotRefreshPending = false
        snapshotRequestInFlight = true
        do {
            try send(HerdrLocalSessionMonitor.snapshotRequest)
        } catch {
            snapshotRequestInFlight = false
            fail()
        }
    }

    private func receivedSnapshot(_ groups: [AgentGroup]) {
        snapshotRequestInFlight = false
        let paneIDs = Set(groups.flatMap(\.agents).map(\.paneID))
        let stage = lock.withLock { bootstrapStage }
        if stage == .preliminary {
            lock.withLock {
                subscribedPaneIDs = paneIDs
                bootstrapStage = .subscribing
            }
            initialSnapshotReceived.signal()
            return
        }
        if stage == .subscribing { return }

        publish(groups)
        let paneIDsMatch = paneIDs == lock.withLock { subscribedPaneIDs }
        if stage == .authoritative {
            lock.withLock {
                bootstrapStage = .complete
                initialSnapshotSucceeded = paneIDsMatch
            }
            initialSnapshotReceived.signal()
        }
        guard paneIDsMatch else { fail(); return }
        if snapshotRefreshPending { scheduleSnapshot(delay: 0) }
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
