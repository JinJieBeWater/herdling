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

enum LocalSessionMonitorEvent: Sendable {
    case sessions([HerdrClient.LoadedSession])
    case unavailable
}

protocol LocalSessionMonitoring: Sendable {
    func start(handler: @escaping @Sendable (LocalSessionMonitorEvent) async -> Void) async
    func stop() async
}

actor HerdrLocalSessionMonitor: LocalSessionMonitoring {
    private let configDirectory: URL
    private var handler: (@Sendable (LocalSessionMonitorEvent) async -> Void)?
    private var discoveryTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var connections: [String: HerdrSocketConnection] = [:]
    private var snapshots: [String: HerdrClient.LoadedSession] = [:]
    private var snapshotGenerations = SnapshotGenerationLedger()
    private var endpointOrder: [String] = []

    init(configDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr")) {
        self.configDirectory = configDirectory
    }

    func start(handler: @escaping @Sendable (LocalSessionMonitorEvent) async -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        discover()
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

    private func discover() {
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
            do { try connection.start() }
            catch {
                connections.removeValue(forKey: endpoint.path)?.stop()
            }
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
        let event: LocalSessionMonitorEvent
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
        _ event: LocalSessionMonitorEvent,
        handler: @escaping @Sendable (LocalSessionMonitorEvent) async -> Void
    ) {
        let previous = publicationTask
        publicationTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await handler(event)
        }
    }
}

private final class HerdrSocketConnection: @unchecked Sendable {
    let id = UUID()
    private let endpoint: HerdrSocketEndpoint
    private let onSnapshot: @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void
    private let onEnd: @Sendable (UUID, HerdrSocketEndpoint) -> Void
    private let queue = DispatchQueue(label: "dev.herdr.Herdling.socket")
    private let lock = NSLock()
    private let subscriptionStarted = DispatchSemaphore(value: 0)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var snapshotScheduled = false
    private var snapshotGeneration: UInt64 = 0
    private var subscribedPaneIDs: Set<String> = []
    private var finished = false
    private var stopped = false

    init(
        endpoint: HerdrSocketEndpoint,
        onSnapshot: @escaping @Sendable (UUID, HerdrSocketEndpoint, UInt64, [AgentGroup]) -> Void,
        onEnd: @escaping @Sendable (UUID, HerdrSocketEndpoint) -> Void
    ) {
        self.endpoint = endpoint
        self.onSnapshot = onSnapshot
        self.onEnd = onEnd
    }

    func start() throws {
        let preliminaryGroups = try querySnapshot()
        subscribedPaneIDs = Set(preliminaryGroups.flatMap(\.agents).map(\.paneID))

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-U", endpoint.path]
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
        lock.withLock {
            self.process = process
            input = inputPipe.fileHandleForWriting
            output = outputPipe.fileHandleForReading
        }
        try process.run()
        try send(HerdrLocalSessionMonitor.subscriptionRequest(paneIDs: subscribedPaneIDs))
        guard subscriptionStarted.wait(timeout: .now() + 3) == .success else {
            throw CommandRunner.Error.timedOut
        }
        var bootstrapError: Error?
        queue.sync {
            do {
                let authoritativeGroups = try querySnapshot()
                publish(authoritativeGroups)
                if Set(authoritativeGroups.flatMap(\.agents).map(\.paneID)) != subscribedPaneIDs {
                    fail()
                }
            } catch {
                bootstrapError = error
            }
        }
        if let bootstrapError { throw bootstrapError }
    }

    func stop() {
        let values = lock.withLock { () -> (Process?, FileHandle?) in
            stopped = true
            output?.readabilityHandler = nil
            return (process, input)
        }
        try? values.1?.close()
        if values.0?.isRunning == true { values.0?.terminate() }
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
            case .snapshot, .other:
                break
            }
        } catch {
            // A malformed line must not tear down an otherwise healthy event stream.
        }
    }

    private func scheduleSnapshot(delay: TimeInterval) {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.snapshotScheduled = false
            self.fetchSnapshot()
        }
    }

    private func fetchSnapshot() {
        do {
            let groups = try querySnapshot()
            publish(groups)
            let paneIDs = Set(groups.flatMap(\.agents).map(\.paneID))
            if paneIDs != subscribedPaneIDs { fail() }
        } catch {
            fail()
        }
    }

    private func querySnapshot() throws -> [AgentGroup] {
        let request = Data((#"{"id":"snapshot","method":"session.snapshot","params":{}}"# + "\n").utf8)
        let response = try CommandRunner.run(
            "/usr/bin/nc",
            ["-U", endpoint.path],
            timeout: 3,
            standardInput: request
        )
        guard let line = response.split(separator: 0x0A).first,
              case let .snapshot(groups) = try HerdrSocketMessage.decode(Data(line), refreshedAt: .now)
        else { throw CommandRunner.Error.failed("Herdr returned no session snapshot.") }
        return groups
    }

    private func publish(_ groups: [AgentGroup]) {
        snapshotGeneration &+= 1
        onSnapshot(id, endpoint, snapshotGeneration, groups)
    }

    private func send(_ request: String) throws {
        guard let data = (request + "\n").data(using: .utf8) else { return }
        let handle = lock.withLock { input }
        try handle?.write(contentsOf: data)
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

    // ponytail: one persistent system nc process per session avoids a custom AF_UNIX transport;
    // replace it only if sandboxing or profiling proves the process cost matters.
}
