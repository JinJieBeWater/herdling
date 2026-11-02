import Foundation

enum HerdrCoreMonitorEvent: Sendable {
    case snapshot(HerdrCoreSnapshot)
    case unavailable(reason: String? = nil, retryAt: Date? = nil)
    case absent
}

protocol HerdrCoreMonitoring: Sendable {
    func start(handler: @escaping @Sendable (HerdrCoreMonitorEvent) async -> Void) async
    func stop() async
    func retry() async
}

actor HerdrCoreMonitor: HerdrCoreMonitoring {
    private let client: HerdrCoreClient
    private let retryInterval: TimeInterval
    private let machineRefreshInterval: TimeInterval
    private var epoch: UInt64 = 0
    private var task: Task<Void, Never>?
    private var transport: (any HerdrCoreTransport)?
    private var handler: (@Sendable (HerdrCoreMonitorEvent) async -> Void)?
    private var hasConnected = false

    init(client: HerdrCoreClient = .init(), retryInterval: TimeInterval = 5, machineRefreshInterval: TimeInterval = 15) {
        self.client = client
        self.retryInterval = retryInterval
        self.machineRefreshInterval = machineRefreshInterval
    }

    func start(handler: @escaping @Sendable (HerdrCoreMonitorEvent) async -> Void) async {
        guard self.handler == nil else { return }
        self.handler = handler
        launch()
    }

    func stop() async {
        epoch &+= 1
        task?.cancel()
        task = nil
        transport?.close()
        transport = nil
        handler = nil
        hasConnected = false
    }

    func retry() async {
        guard handler != nil else { return }
        epoch &+= 1
        task?.cancel()
        transport?.close()
        transport = nil
        launch()
    }

    private func launch() {
        epoch &+= 1
        let generation = epoch
        let client = client
        let retryInterval = max(0.01, retryInterval)
        let machineRefreshInterval = max(0.01, machineRefreshInterval)
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let rpc = try client.connect()
                    defer { rpc.close() }
                    guard await self?.register(rpc.transport, epoch: generation) == true else { return }
                    let hello = try rpc.hello()
                    let machines = try rpc.machines()
                    let subscription: HerdrCoreSubscription = try rpc.call("events.subscribe")
                    var directory = try HerdrCoreDirectory(hello: hello, socketPath: client.socketPath!, machines: machines, subscription: subscription)
                    try directory.updateMachines(client.currentMachines(entryCoreID: hello.core.id))
                    guard await self?.publish(.snapshot(try directory.snapshot()), epoch: generation) == true else { return }
                    var lastMessage = Date()
                    var refreshAt = Date().addingTimeInterval(machineRefreshInterval)
                    while !Task.isCancelled {
                        if let line = try rpc.transport.readLine(timeout: 1) {
                            if try HerdrCoreDirectory.needsMachineRefresh(line) {
                                try directory.updateMachines(client.currentMachines(entryCoreID: hello.core.id))
                            }
                            let changed = try directory.consume(line)
                            lastMessage = .now
                            if changed {
                                guard await self?.publish(.snapshot(try directory.snapshot()), epoch: generation) == true else { return }
                            }
                        }
                        guard Date().timeIntervalSince(lastMessage) < 40 else {
                            throw HerdrCoreError.unavailable("Core heartbeat timed out.")
                        }
                        if Date() >= refreshAt {
                            try directory.updateMachines(client.currentMachines(entryCoreID: hello.core.id))
                            guard await self?.publish(.snapshot(try directory.snapshot()), epoch: generation) == true else { return }
                            refreshAt = Date().addingTimeInterval(machineRefreshInterval)
                        }
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    let absent = (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOENT)
                    guard await self?.failed(error.localizedDescription, absent: absent, retryAt: Date().addingTimeInterval(retryInterval), epoch: generation) == true else { return }
                    do { try await Task.sleep(for: .seconds(retryInterval)) }
                    catch { return }
                }
            }
        }
    }

    private func register(_ transport: any HerdrCoreTransport, epoch: UInt64) -> Bool {
        guard self.epoch == epoch, handler != nil else { transport.close(); return false }
        self.transport = transport
        return true
    }

    private func publish(_ event: HerdrCoreMonitorEvent, epoch: UInt64) async -> Bool {
        guard self.epoch == epoch, let handler else { return false }
        if case .snapshot = event { hasConnected = true }
        await handler(event)
        return self.epoch == epoch && self.handler != nil
    }

    private func failed(_ reason: String, absent: Bool, retryAt: Date, epoch: UInt64) async -> Bool {
        guard self.epoch == epoch else { return false }
        transport = nil
        return await publish(absent && !hasConnected ? .absent : .unavailable(reason: reason, retryAt: retryAt), epoch: epoch)
    }
}
