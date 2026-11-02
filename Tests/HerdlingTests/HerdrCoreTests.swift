import Darwin
import Foundation
import Testing
@testable import Herdling

struct HerdrCoreTests {
    @Test
    func nativeSocketHandlesFragmentedLinesAndCancellation() async throws {
        let path = "/tmp/hc-fixture-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)
        let server = Task.detached {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            try #require(poll(&descriptor, 1, 2_000) > 0)
            let peer = accept(listener, nil, nil)
            try #require(peer >= 0)
            defer { Darwin.close(peer) }
            var received = Data()
            while !received.contains(0x0A) {
                var bytes = [UInt8](repeating: 0, count: 256)
                descriptor = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
                try #require(poll(&descriptor, 1, 2_000) > 0)
                let count = Darwin.read(peer, &bytes, bytes.count)
                try #require(count > 0)
                received.append(contentsOf: bytes.prefix(count))
            }
            for chunk in ["first", " line\nsecond\n"] {
                let bytes = Array(chunk.utf8)
                let written = bytes.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
                try #require(written == bytes.count)
            }
            return received
        }
        let stream = try HerdrCoreSocket(path: path)
        defer { stream.close() }
        #expect(stream.peerProcessID == getpid())
        try stream.write(Data("request".utf8))
        #expect(try stream.readLine(timeout: 2) == Data("first line".utf8))
        #expect(try stream.readLine(timeout: 2) == Data("second".utf8))
        #expect(try await server.value == Data("request\n".utf8))
        stream.close()
        #expect(stream.peerProcessID == nil)
        #expect(throws: (any Error).self) { try stream.readLine(timeout: 20) }
    }

    @Test
    func nativePathsRespectOverridesAndConfigWithoutStartingAnything() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        #expect(try HerdrCoreClient.defaultSocketPath(environment: ["HC_SOCKET": "/explicit.sock", "XDG_RUNTIME_DIR": "/run-fixture"], homeDirectory: home) == "/explicit.sock")
        #expect(try HerdrCoreClient.defaultSocketPath(environment: ["HC_SESSION": " other ", "XDG_RUNTIME_DIR": "/run-fixture"], homeDirectory: home) == "/run-fixture/herdr-core/other.sock")
        #expect(try HerdrCoreClient.configuredSocket("socket = '/a #b.sock' # comment\n[other]\nsocket = '/ignored'") == "/a #b.sock")
        #expect(try HerdrCoreClient.configuredSocket(#"socket = "/a\u0020b.sock""#) == "/a b.sock")
        #expect(throws: (any Error).self) { try HerdrCoreClient.configuredSocket("socket = 42") }
        #expect(throws: (any Error).self) { try HerdrCoreClient.configuredSocket("socket = '/one'\nsocket = '/two'") }
        #expect(throws: (any Error).self) { try HerdrCoreClient.defaultSocketPath(environment: ["HC_SESSION": "../other"], homeDirectory: home) }
    }

    @Test
    func sameShortIDsRemainDistinctAndRemoteHealthIsLocalToMachine() throws {
        var directory = try makeDirectory(terminals: [terminal("t7", state: "working"), terminal("box/t7", state: "done"), terminal("unknown/t7", state: "idle"), terminal("t8", nativeState: "finished")])
        var snapshot = try directory.snapshot()
        #expect(snapshot.terminals.count == 2)
        #expect(Set(snapshot.terminals.map(\.target.id)) == [CoreTerminalID(coreID: "entry-A", terminalID: "t7"), CoreTerminalID(coreID: "remote-B", terminalID: "t7")])
        #expect(snapshot.terminals.first { $0.machineName == "box" }?.rawStatus == "done")
        try directory.updateMachines([.init(name: "box", id: "remote-B", target: "user@box", state: "unreachable", why: "network")])
        snapshot = try directory.snapshot()
        #expect(snapshot.terminals.first { $0.machineName == nil }?.online == true)
        #expect(snapshot.terminals.first { $0.machineName == "box" }?.online == false)
        #expect(snapshot.machines.first?.why == "network")
        #expect(throws: (any Error).self) {
            try directory.updateMachines([.init(name: "box", id: "remote-C", target: "other@box", state: "connected")])
        }
        #expect(try directory.snapshot().terminals.first { $0.machineName == "box" }?.target.id.coreID == "remote-B")
        let otherEntry = try makeDirectory(entryID: "entry-C", terminals: [terminal("t7")]).snapshot()
        #expect(otherEntry.terminals[0].target.id != snapshot.terminals.first { $0.machineName == nil }?.target.id)
    }

    @Test
    func eventsApplyRootStatusOnceAndMissedReplacesDirectory() throws {
        var directory = try makeDirectory(terminals: [terminal("t7")])
        #expect(try directory.snapshot().terminals[0].rawStatus == nil)
        #expect(try directory.consume(Data(#"{"method":"event","params":{"seq":11,"type":"status","terminal":"t7","data":{"status":{"state":"blocked","app":"pi","msg":"input"},"records":{"extra":{"state":"working"}},"reported":true}}}"#.utf8), now: Date(timeIntervalSince1970: 123)))
        let blocked = try directory.snapshot()
        #expect(blocked.terminals.count == 1)
        #expect(blocked.terminals[0].rawStatus == "blocked")
        #expect(blocked.terminals[0].statusChangedAt == Date(timeIntervalSince1970: 123))
        #expect(blocked.terminals[0].statusMessage == "input")
        let missed = "{\"method\":\"missed\",\"params\":{\"seq\":20,\"terminals\":[\(terminal("t9", state: "error"))]}}"
        #expect(try directory.consume(Data(missed.utf8)))
        #expect(try directory.snapshot().terminals.map(\.target.address) == ["t9"])
        #expect(try !directory.consume(Data(#"{"method":"event","params":{"seq":19,"type":"removed","terminal":"t9","data":{}}}"#.utf8)))
        #expect(throws: (any Error).self) { try directory.consume(Data(#"{"method":"heartbeat","params":{"seq":22}}"#.utf8)) }
        #expect(throws: (any Error).self) { try directory.consume(Data(#"{"method":"event","params":{"seq":22,"type":"removed","terminal":"t9","data":{}}}"#.utf8)) }
    }

    @Test
    func finishedAndLostAreNeverTranslatedIntoDoneOrIdle() throws {
        var directory = try makeDirectory(terminals: [terminal("t7", state: "working")])
        _ = try directory.consume(Data(#"{"method":"event","params":{"seq":11,"type":"lost","terminal":"t7","data":{"reason":"holder_lost"}}}"#.utf8))
        #expect(try directory.snapshot().terminals[0].online == false)
        #expect(try directory.snapshot().terminals[0].rawStatus == "working")
        _ = try directory.consume(Data(#"{"method":"event","params":{"seq":12,"type":"finished","terminal":"t7","data":{}}}"#.utf8))
        #expect(try directory.snapshot().terminals.isEmpty)
    }

    @Test
    func validateUsesEntryAndHostingIdentityAndOmitsCaller() throws {
        let stream = CoreFixtureTransport(terminalJSON: terminal("box/t7"))
        let client = HerdrCoreClient(socketPath: "/fixture.sock", transportFactory: { _ in stream })
        let target = CoreTerminalTarget(id: .init(coreID: "remote-B", terminalID: "t7"), socketPath: "/fixture.sock", entryCoreID: "entry-A", address: "box/t7")
        try client.validate(target)
        #expect(stream.methods == ["hello", "machine.list", "terminal.get"])
        #expect((stream.requests.last?["params"] as? [String: String])?["terminal"] == "remote-B/t7")
        #expect(stream.requests.allSatisfy { $0["caller"] == nil && ($0["params"] as? [String: Any])?["caller"] == nil })
        let wrong = CoreTerminalTarget(id: .init(coreID: "entry-A", terminalID: "t7"), socketPath: "/fixture.sock", entryCoreID: "entry-A", address: "box/t7")
        #expect(throws: (any Error).self) { try client.validate(wrong) }
        #expect(throws: (any Error).self) { try client.validate(.init(id: target.id, socketPath: target.socketPath, entryCoreID: "entry-C", address: target.address)) }
        #expect(throws: (any Error).self) { try HerdrCoreClient.addressParts("box/t7;touch /tmp/no") }
        #expect(throws: (any Error).self) { try HerdrCoreClient.addressParts("t") }
        #expect(try HerdrCoreClient.addressParts("box/t1b").terminal == "t1b")
        #expect(try HerdrCoreClient.addressParts("t9z").terminal == "t9z")
        #expect(throws: (any Error).self) { try HerdrCoreClient.addressParts("t0") }
        #expect(throws: (any Error).self) { try HerdrCoreClient.addressParts("t1a") }
        #expect(throws: (any Error).self) { try HerdrCoreClient.addressParts("t9zzzzzzzzzzzz") }
    }

    @Test
    func retryRejectsLateOldConnectionAndStopDoesNotPublish() async throws {
        let factory = CoreFixtureFactory()
        let client = HerdrCoreClient(socketPath: "/fixture.sock", transportFactory: { _ in factory.make() })
        let monitor = HerdrCoreMonitor(client: client, retryInterval: 0.01, machineRefreshInterval: 60)
        let events = CoreFixtureEvents()
        await monitor.start { await events.receive($0) }
        try await events.waitForSnapshots(1)
        await monitor.retry()
        try await events.waitForSnapshots(2)
        let old = try #require(factory.streams.first)
        old.enqueue(#"{"method":"event","params":{"seq":11,"type":"title","terminal":"t7","data":{"title":"late"}}}"#)
        await monitor.stop()
        let count = await events.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(await events.count == count)
        #expect(factory.streams.allSatisfy { $0.isClosed })
        #expect(await events.titles.contains("late") == false)
    }

    @Test
    func absentIsQuietUntilFirstConnectionThenLossIsUnavailable() async throws {
        let missing = HerdrCoreClient(socketPath: "/unused.sock", transportFactory: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) })
        let monitor = HerdrCoreMonitor(client: missing, retryInterval: 60)
        let events = CoreFixtureEvents()
        await monitor.start { await events.receive($0) }
        try await events.waitForCount(1)
        await monitor.stop()
        #expect(await events.absent == 1)
        let stream = CoreFixtureTransport(terminalJSON: terminal("t7"))
        let connected = HerdrCoreMonitor(client: .init(socketPath: "/fixture.sock", transportFactory: { _ in stream }), retryInterval: 60)
        let connectedEvents = CoreFixtureEvents()
        await connected.start { await connectedEvents.receive($0) }
        try await connectedEvents.waitForSnapshots(1)
        stream.close()
        try await connectedEvents.waitForCount(2)
        await connected.stop()
        #expect(await connectedEvents.unavailable == 1)
        #expect(await connectedEvents.absent == 0)
    }
}

private func terminal(_ address: String, state: String? = nil, nativeState: String = "live") -> String {
    let status = state.map { "{\"state\":\"\($0)\"}" } ?? "null"
    return "{\"address\":\"\(address)\",\"cwd\":\"/fixture\",\"state\":\"\(nativeState)\",\"title\":\"same name\",\"pid\":42,\"status\":\(status),\"reported\":\(state != nil)}"
}

private func makeDirectory(entryID: String = "entry-A", terminals: [String]) throws -> HerdrCoreDirectory {
    try HerdrCoreDirectory(
        hello: .init(generation: 1, core: .init(id: entryID, name: "fixture")), socketPath: "/fixture.sock",
        machines: [.init(name: "box", id: "remote-B", target: "user@box", state: "connected")],
        subscription: JSONDecoder().decode(HerdrCoreSubscription.self, from: Data("{\"seq\":10,\"terminals\":[\(terminals.joined(separator: ","))]}".utf8))
    )
}

private final class CoreFixtureTransport: HerdrCoreTransport, @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [Data] = []
    private var closed = false
    private var recorded: [[String: Any]] = []
    private let terminalJSON: String

    init(terminalJSON: String) { self.terminalJSON = terminalJSON }
    var requests: [[String: Any]] { condition.withLock { recorded } }
    var methods: [String] { requests.compactMap { $0["method"] as? String } }
    var isClosed: Bool { condition.withLock { closed } }

    func write(_ line: Data) throws {
        let request = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        condition.withLock { recorded.append(request) }
        let id = try #require(request["id"] as? String)
        let result: String
        switch request["method"] as? String {
        case "hello": result = #"{"generation":1,"core":{"id":"entry-A","name":"fixture"}}"#
        case "machine.list": result = #"{"machines":[{"name":"box","id":"remote-B","target":"user@box","state":"connected"}]}"#
        case "terminal.get": result = terminalJSON
        case "events.subscribe": result = "{\"seq\":10,\"terminals\":[\(terminalJSON)]}"
        default: throw HerdrCoreError.invalid("Unexpected fixture request")
        }
        enqueue("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"result\":\(result)}")
    }

    func readLine(timeout: TimeInterval) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while lines.isEmpty && !closed {
            if !condition.wait(until: deadline) { return nil }
        }
        if !lines.isEmpty { return lines.removeFirst() }
        throw HerdrCoreError.unavailable("fixture closed")
    }

    func enqueue(_ line: String) {
        condition.withLock { lines.append(Data(line.utf8)); condition.broadcast() }
    }

    func close() { condition.withLock { closed = true; condition.broadcast() } }
}

private final class CoreFixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [CoreFixtureTransport] = []
    var streams: [CoreFixtureTransport] { lock.withLock { created } }
    func make() -> CoreFixtureTransport {
        let stream = CoreFixtureTransport(terminalJSON: terminal("t7"))
        lock.withLock { created.append(stream) }
        return stream
    }
}

private actor CoreFixtureEvents {
    var count = 0
    var titles: [String] = []
    var snapshots = 0
    var absent = 0
    var unavailable = 0
    func receive(_ event: HerdrCoreMonitorEvent) {
        count += 1
        switch event {
        case let .snapshot(snapshot): snapshots += 1; titles += snapshot.terminals.map(\.title)
        case .absent: absent += 1
        case .unavailable: unavailable += 1
        }
    }
    func waitForSnapshots(_ minimum: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while snapshots < minimum && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(snapshots >= minimum)
    }
    func waitForCount(_ minimum: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while count < minimum && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(count >= minimum)
    }
}
