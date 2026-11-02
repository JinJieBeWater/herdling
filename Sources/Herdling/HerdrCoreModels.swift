import Foundation

struct HerdrCoreTerminal: Equatable, Sendable {
    let target: CoreTerminalTarget
    let title: String
    let rawStatus: String?
    let statusChangedAt: Date?
    let cwd: String
    let machineName: String?
    let machineTarget: String?
    let online: Bool
    let reported: Bool
    let state: String
    let statusApp: String?
    let statusMessage: String?
}

struct HerdrCoreMachine: Codable, Equatable, Sendable {
    let name: String
    let id: String
    let target: String
    let state: String
    let why: String?
    let via: Bool

    var online: Bool { state == "connected" }

    init(name: String, id: String, target: String, state: String, why: String? = nil, via: Bool = false) {
        self.name = name
        self.id = id
        self.target = target
        self.state = state
        self.why = why
        self.via = via
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        id = try values.decode(String.self, forKey: .id)
        target = try values.decode(String.self, forKey: .target)
        state = try values.decode(String.self, forKey: .state)
        why = try values.decodeIfPresent(String.self, forKey: .why)
        via = try values.decodeIfPresent(Bool.self, forKey: .via) ?? false
    }
}

struct HerdrCoreSnapshot: Equatable, Sendable {
    let entryCoreID: String
    let socketPath: String
    let terminals: [HerdrCoreTerminal]
    let machines: [HerdrCoreMachine]
}

struct HerdrCoreHello: Decodable, Sendable {
    struct Core: Decodable, Sendable { let id: String; let name: String }
    let generation: UInt32
    let core: Core
}

struct HerdrCoreWireTerminal: Codable, Sendable {
    struct Status: Codable, Sendable {
        let state: String
        let app: String?
        let msg: String?
        let title: String?
    }
    struct Foreground: Codable, Sendable { let cwd: String }
    let address: String
    var cwd: String
    var state: String
    var title: String?
    let name: String?
    var status: Status?
    var status_ms: UInt64?
    var foreground: Foreground?
    var reported: Bool?
    var pid: UInt32?
    var reason: String?
}

struct HerdrCoreSubscription: Decodable, Sendable {
    let seq: UInt64
    let terminals: [HerdrCoreWireTerminal]
}

enum HerdrCoreJSON: Codable, Sendable {
    case object([String: HerdrCoreJSON]), array([HerdrCoreJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

struct HerdrCoreDirectory: Sendable {
    let entryCoreID: String
    let socketPath: String
    private(set) var machines: [HerdrCoreMachine]
    private(set) var sequence: UInt64
    private var terminals: [String: HerdrCoreWireTerminal]

    init(hello: HerdrCoreHello, socketPath: String, machines: [HerdrCoreMachine], subscription: HerdrCoreSubscription) throws {
        entryCoreID = hello.core.id
        self.socketPath = socketPath
        self.machines = machines
        sequence = subscription.seq
        terminals = [:]
        try replace(subscription)
    }

    mutating func updateMachines(_ machines: [HerdrCoreMachine]) throws {
        let identity = { (records: [HerdrCoreMachine]) in
            Dictionary(grouping: records, by: \.name).mapValues { Set($0.map(\.id)) }
        }
        guard identity(self.machines) == identity(machines) else {
            throw HerdrCoreError.invalid("Core machine identities changed; refreshing the directory.")
        }
        self.machines = machines
    }

    static func needsMachineRefresh(_ line: Data) throws -> Bool {
        struct Probe: Decodable {
            struct Params: Decodable { let type: String?; let terminal: String? }
            let method: String
            let params: Params
        }
        let notification = try JSONDecoder().decode(Probe.self, from: line)
        return notification.method == "missed" || (notification.method == "event"
            && ["created", "restarted"].contains(notification.params.type ?? "")
            && notification.params.terminal?.contains("/") == true)
    }

    mutating func replace(_ snapshot: HerdrCoreSubscription) throws {
        var replacement: [String: HerdrCoreWireTerminal] = [:]
        for terminal in snapshot.terminals {
            _ = try HerdrCoreClient.addressParts(terminal.address)
            guard replacement.updateValue(terminal, forKey: terminal.address) == nil else {
                throw HerdrCoreError.invalid("Duplicate Core terminal address.")
            }
        }
        terminals = replacement
        sequence = snapshot.seq
    }

    /// Returns false for old events, including those already represented by a missed snapshot.
    mutating func consume(_ line: Data, now: Date = .now) throws -> Bool {
        struct Notification: Decodable {
            struct Params: Decodable {
                let seq: UInt64
                let type: String?
                let terminal: String?
                let data: HerdrCoreJSON?
                let terminals: [HerdrCoreWireTerminal]?
            }
            let method: String
            let params: Params
        }
        let notification = try JSONDecoder().decode(Notification.self, from: line)
        let event = notification.params
        if notification.method == "missed" {
            guard event.seq >= sequence, let records = event.terminals else { return false }
            try replace(HerdrCoreSubscription(seq: event.seq, terminals: records))
            return true
        }
        if notification.method == "heartbeat" {
            guard event.seq == sequence else { throw HerdrCoreError.invalid("Core event sequence gap.") }
            return false
        }
        guard notification.method == "event" else { throw HerdrCoreError.invalid("Unknown Core notification.") }
        guard event.seq > sequence else { return false }
        guard sequence < UInt64.max, event.seq == sequence + 1 else {
            throw HerdrCoreError.invalid("Core event sequence gap.")
        }
        sequence = event.seq
        guard let address = event.terminal else { return false } // document event
        _ = try HerdrCoreClient.addressParts(address)
        switch event.type {
        case "created", "restarted":
            guard let data = event.data else { throw HerdrCoreError.invalid("Missing Core terminal record.") }
            let terminal = try data.decode(HerdrCoreWireTerminal.self)
            guard terminal.address == address else { throw HerdrCoreError.invalid("Core event address mismatch.") }
            terminals[address] = terminal
        case "removed": terminals.removeValue(forKey: address)
        case "status":
            struct Patch: Decodable { let status: HerdrCoreWireTerminal.Status?; let reported: Bool }
            guard let data = event.data else { throw HerdrCoreError.invalid("Missing Core status.") }
            let patch = try data.decode(Patch.self)
            if var terminal = terminals[address] {
                if terminal.status?.state != patch.status?.state {
                    // shortcut: status events omit status_ms; use receipt time until the protocol supplies it.
                    terminal.status_ms = patch.status == nil ? nil : UInt64(max(0, now.timeIntervalSince1970 * 1000))
                }
                terminal.status = patch.status
                terminal.reported = patch.reported
                terminals[address] = terminal
            } else { throw HerdrCoreError.invalid("Core status for unknown terminal.") }
        case "title":
            struct Patch: Decodable { let title: String }
            guard let data = event.data else { throw HerdrCoreError.invalid("Missing Core title.") }
            terminals[address]?.title = try data.decode(Patch.self).title
        case "foreground":
            terminals[address]?.foreground = try event.data?.decode(Optional<HerdrCoreWireTerminal.Foreground>.self)
        case "lost":
            struct Patch: Decodable { let reason: String? }
            guard let data = event.data else { throw HerdrCoreError.invalid("Missing Core loss reason.") }
            terminals[address]?.reason = try data.decode(Patch.self).reason
            terminals[address]?.pid = nil
            terminals[address]?.foreground = nil
        case "finished":
            terminals[address]?.state = "finished"
            terminals[address]?.foreground = nil
            terminals[address]?.status = nil
        default: return false // Facts without roster presentation, including extra OSC records.
        }
        return true
    }

    func snapshot() throws -> HerdrCoreSnapshot {
        let records = try terminals.values.filter { $0.state == "live" }.sorted { $0.address < $1.address }.compactMap { terminal -> HerdrCoreTerminal? in
            let parts = try HerdrCoreClient.addressParts(terminal.address)
            let machine: HerdrCoreMachine?
            if let name = parts.machine {
                let matches = machines.filter { $0.name == name && !$0.id.isEmpty }
                guard matches.count == 1 else { return nil } // Unknown remote identity never becomes local.
                machine = matches[0]
            } else { machine = nil }
            let coreID = machine?.id ?? entryCoreID
            let statusTitle = terminal.status?.title.flatMap { $0.isEmpty ? nil : $0 }
            let title = terminal.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? statusTitle ?? terminal.title.flatMap { $0.isEmpty ? nil : $0 } ?? terminal.address
            return HerdrCoreTerminal(
                target: CoreTerminalTarget(id: CoreTerminalID(coreID: coreID, terminalID: parts.terminal), socketPath: socketPath, entryCoreID: entryCoreID, address: terminal.address),
                title: title,
                rawStatus: terminal.status?.state,
                statusChangedAt: terminal.status_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                cwd: terminal.foreground?.cwd ?? terminal.cwd,
                machineName: machine?.name,
                machineTarget: machine.flatMap { $0.via ? nil : $0.target },
                online: (machine?.online ?? true) && terminal.pid != nil && terminal.reason != "spawn_pending",
                reported: terminal.reported ?? false,
                state: terminal.state,
                statusApp: terminal.status?.app,
                statusMessage: terminal.status?.msg
            )
        }
        return HerdrCoreSnapshot(entryCoreID: entryCoreID, socketPath: socketPath, terminals: records, machines: machines)
    }
}
