import Darwin
import Foundation

struct HerdrCoreClient: Sendable {
    typealias TransportFactory = @Sendable (String) throws -> any HerdrCoreTransport
    let socketPath: String?
    private let endpointError: String?
    private let transportFactory: TransportFactory

    init(
        socketPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        transportFactory: @escaping TransportFactory = { try HerdrCoreSocket(path: $0) }
    ) {
        do {
            let path = try socketPath ?? Self.defaultSocketPath(environment: environment, homeDirectory: homeDirectory)
            guard !path.isEmpty, !path.contains("\0") else { throw HerdrCoreError.invalid("Invalid Core socket path.") }
            self.socketPath = URL(fileURLWithPath: path).path
            endpointError = nil
        } catch {
            self.socketPath = nil
            endpointError = error.localizedDescription
        }
        self.transportFactory = transportFactory
    }

    func connect() throws -> HerdrCoreRPC {
        guard let socketPath else { throw HerdrCoreError.invalid(endpointError ?? "Missing Core endpoint.") }
        return HerdrCoreRPC(transport: try transportFactory(socketPath))
    }

    func currentMachines(entryCoreID: String) throws -> [HerdrCoreMachine] {
        let rpc = try connect()
        defer { rpc.close() }
        guard try rpc.hello().core.id == entryCoreID else { throw HerdrCoreError.invalid("Core identity changed.") }
        return try rpc.machines()
    }

    func validate(_ target: CoreTerminalTarget) throws {
        _ = try Self.addressParts(target.address)
        guard socketPath == target.socketPath, !target.entryCoreID.isEmpty, !target.id.coreID.isEmpty else {
            throw HerdrCoreError.invalid("Core endpoint changed; refresh the terminal list.")
        }
        let rpc = try connect()
        defer { rpc.close() }
        let hello = try rpc.hello()
        guard hello.core.id == target.entryCoreID else {
            throw HerdrCoreError.invalid("Core identity changed; refresh the terminal list.")
        }
        let parts = try Self.addressParts(target.address)
        let hostID: String
        if let name = parts.machine {
            let machines = try rpc.machines().filter { $0.name == name && $0.online }
            guard machines.count == 1 else { throw HerdrCoreError.unavailable("Core machine is unavailable.") }
            hostID = machines[0].id
        } else { hostID = hello.core.id }
        guard hostID == target.id.coreID, parts.terminal == target.id.terminalID else {
            throw HerdrCoreError.invalid("Core terminal identity changed; refresh the terminal list.")
        }
        // Omitting caller avoids native parent/child seen mutation.
        let selector = parts.machine == nil ? parts.terminal : "\(hostID)/\(parts.terminal)"
        let terminal: HerdrCoreWireTerminal = try rpc.call("terminal.get", params: ["terminal": selector])
        guard terminal.address == target.address, terminal.state == "live", terminal.pid != nil,
              terminal.reason != "spawn_pending" else {
            throw HerdrCoreError.unavailable("Core terminal is unavailable.")
        }
    }

    static func addressParts(_ address: String) throws -> (machine: String?, terminal: String) {
        let parts = address.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2,
              let terminal = parts.last, validTerminalID(terminal),
              parts.count == 1 || (!parts[0].isEmpty && parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) })) else {
            throw HerdrCoreError.invalid("Invalid native Core terminal address.")
        }
        return (parts.count == 2 ? parts[0] : nil, terminal)
    }

    private static func validTerminalID(_ id: String) -> Bool {
        let symbols = Array("0123456789bcdfghjkmnpqrstvwxyz".utf8)
        let bytes = Array(id.utf8)
        guard bytes.count >= 2, bytes[0] == 116, (49...57).contains(bytes[1]) else { return false }
        var value = UInt64(bytes[1] - 49)
        var before: UInt64 = 0
        var size: UInt64 = 9
        for byte in bytes.dropFirst(2) {
            guard let digit = symbols.firstIndex(of: byte), size <= UInt64(UInt32.max) else { return false }
            value = value * 30 + UInt64(digit)
            before += size
            size *= 30
        }
        return before + value < UInt64(UInt32.max)
    }

    static func defaultSocketPath(environment: [String: String], homeDirectory: URL) throws -> String {
        let session = session(environment["HC_SESSION"])
        guard session != ".", session != "..", !session.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || "/\\:*?\"<>|".unicodeScalars.contains($0)
        }) else { throw HerdrCoreError.invalid("Invalid HC_SESSION.") }
        if let explicit = nonempty(environment["HC_SOCKET"]) { return explicit }
        let configHome = nonempty(environment["XDG_CONFIG_HOME"]) ?? homeDirectory.appendingPathComponent(".config").path
        let config = URL(fileURLWithPath: configHome).appendingPathComponent("herdr-core/config.toml")
        if FileManager.default.fileExists(atPath: config.path) {
            if let path = try configuredSocket(String(contentsOf: config, encoding: .utf8)) { return path }
        }
        if let runtime = nonempty(environment["XDG_RUNTIME_DIR"]) {
            return URL(fileURLWithPath: runtime).appendingPathComponent("herdr-core/\(session).sock").path
        }
        let systemRuntime = "/run/user/\(getuid())"
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: systemRuntime, isDirectory: &isDirectory), isDirectory.boolValue {
            return "\(systemRuntime)/herdr-core/\(session).sock"
        }
        let state = nonempty(environment["XDG_STATE_HOME"]) ?? homeDirectory.appendingPathComponent(".local/state").path
        return URL(fileURLWithPath: state).appendingPathComponent("herdr-core/\(session)/\(session).sock").path
    }

    static func configuredSocket(_ config: String) throws -> String? {
        var result: String?
        for line in config.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            guard ["socket", "\"socket\"", "'socket'"].contains(key) else { continue }
            guard result == nil else { throw HerdrCoreError.invalid("Duplicate Core config socket.") }
            let raw = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            guard let quote = raw.first, quote == "'" || quote == "\"", !raw.hasPrefix(String(repeating: String(quote), count: 3)) else {
                throw HerdrCoreError.invalid("Unsupported Core config socket; set HC_SOCKET explicitly.")
            }
            var escaped = false
            var closing: String.Index?
            for index in raw.indices.dropFirst() {
                if escaped { escaped = false; continue }
                if quote == "\"", raw[index] == "\\" { escaped = true; continue }
                if raw[index] == quote { closing = index; break }
            }
            guard let closing else { throw HerdrCoreError.invalid("Invalid Core config socket.") }
            let tail = raw[raw.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { throw HerdrCoreError.invalid("Invalid Core config socket.") }
            if quote == "'" { result = String(raw[raw.index(after: raw.startIndex)..<closing]) }
            else {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(raw[...closing].utf8)) else {
                    throw HerdrCoreError.invalid("Unsupported Core config socket escape; set HC_SOCKET explicitly.")
                }
                result = value
            }
            guard let result, !result.isEmpty, !result.contains("\0") else { throw HerdrCoreError.invalid("Invalid Core config socket.") }
        }
        return result
    }

    private static func session(_ raw: String?) -> String { nonempty(raw?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "default" }
    private static func nonempty(_ raw: String?) -> String? { raw.flatMap { $0.isEmpty ? nil : $0 } }
}

final class HerdrCoreRPC: Sendable {
    let transport: any HerdrCoreTransport
    init(transport: any HerdrCoreTransport) { self.transport = transport }
    func close() { transport.close() }

    func call<T: Decodable>(_ method: String, params: [String: String] = [:]) throws -> T {
        let id = UUID().uuidString
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        try transport.write(JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]))
        guard let line = try transport.readLine(timeout: 5) else { throw HerdrCoreError.unavailable("Core request timed out.") }
        let envelope = try JSONDecoder().decode(HerdrCoreRPCEnvelope<T>.self, from: line)
        guard envelope.id == id, envelope.jsonrpc == "2.0" else { throw HerdrCoreError.invalid("Invalid Core RPC reply identity.") }
        if let error = envelope.error { throw HerdrCoreError.unavailable(error.message) }
        guard let result = envelope.result else { throw HerdrCoreError.invalid("Missing Core RPC result.") }
        return result
    }

    func hello() throws -> HerdrCoreHello {
        // The numeric generation parameter must not be encoded as a string.
        let id = UUID().uuidString
        try transport.write(JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "hello", "params": ["generation": 1]]))
        guard let line = try transport.readLine(timeout: 5) else { throw HerdrCoreError.unavailable("Core hello timed out.") }
        let reply = try JSONDecoder().decode(HerdrCoreRPCEnvelope<HerdrCoreHello>.self, from: line)
        if let error = reply.error { throw HerdrCoreError.unavailable(error.message) }
        guard reply.id == id, reply.jsonrpc == "2.0", let hello = reply.result, hello.generation == 1, !hello.core.id.isEmpty else {
            throw HerdrCoreError.invalid("Unsupported Core protocol or missing identity.")
        }
        return hello
    }

    func machines() throws -> [HerdrCoreMachine] {
        struct Result: Decodable { let machines: [HerdrCoreMachine] }
        let result: Result = try call("machine.list")
        return result.machines
    }
}

private struct HerdrCoreRPCEnvelope<T: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let jsonrpc: String
    let id: String?
    let result: T?
    let error: Failure?
}
