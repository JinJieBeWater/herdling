import Foundation

struct HerdrClient: Sendable {
    enum ClientError: LocalizedError {
        case notInstalled
        case timedOut
        case failed(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "herdr is not installed."
            case .timedOut:
                "Herdr did not respond before the timeout."
            case let .failed(message):
                message.isEmpty ? "Herdr command failed." : message
            case let .invalidResponse(message):
                "Herdr returned invalid JSON: \(message)"
            }
        }
    }

    struct LoadedSession: Sendable {
        let name: String
        let groups: [AgentGroup]?
        let error: String?
    }

    private let executable: String?

    init(executable: String? = HerdrClient.findExecutable()) {
        self.executable = executable
    }

    func load(_ source: SourceDescriptor = .local) throws -> [LoadedSession] {
        guard let executable else { throw ClientError.notInstalled }
        let names = try Self.parseSessions(run(source, executable: executable, arguments: ["session", "list", "--json"]))

        return names.map { name in
            do {
                let data = try run(source, executable: executable, arguments: ["--session", name, "api", "snapshot"])
                return LoadedSession(name: name, groups: try Self.parseGroups(data), error: nil)
            } catch {
                return LoadedSession(name: name, groups: nil, error: error.localizedDescription)
            }
        }
    }

    func focus(source: SourceDescriptor = .local, session: String, paneID: String) throws {
        guard let executable else { throw ClientError.notInstalled }
        _ = try run(source, executable: executable, arguments: ["--session", session, "agent", "focus", paneID])
    }

    func attachCommand(source: SourceDescriptor = .local, session: String) throws -> String {
        guard let executable else { throw ClientError.notInstalled }
        let cleanEnvironment = ["HERDR_ENV", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID"]
            .map { "-u \($0)" }
            .joined(separator: " ")
        var arguments = ["exec", "/usr/bin/env", cleanEnvironment, Self.shellQuote(executable)]
        if let alias = source.sshAlias { arguments += ["--remote", Self.shellQuote(alias)] }
        arguments += ["--session", Self.shellQuote(session)]
        return arguments.joined(separator: " ")
    }

    static func parseSessions(_ data: Data) throws -> [String] {
        do {
            return try JSONDecoder().decode(SessionList.self, from: data).sessions
                .filter(\.running)
                .map(\.name)
        } catch {
            throw ClientError.invalidResponse(error.localizedDescription)
        }
    }

    static func parseGroups(_ data: Data, refreshedAt: Date = .now) throws -> [AgentGroup] {
        do {
            let snapshot = try JSONDecoder().decode(SnapshotEnvelope.self, from: data).result.snapshot
            let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.label) })
            var agentsByWorkspace: [String: [AgentInfo]] = [:]
            var unknownWorkspaceOrder: [String] = []
            for agent in snapshot.agents {
                if workspaces[agent.workspaceID] == nil, agentsByWorkspace[agent.workspaceID] == nil {
                    unknownWorkspaceOrder.append(agent.workspaceID)
                }
                agentsByWorkspace[agent.workspaceID, default: []].append(AgentInfo(
                    paneID: agent.paneID,
                    title: agent.name ?? agent.terminalTitleStripped ?? agent.terminalTitle ?? agent.agent ?? agent.paneID,
                    status: AgentStatus(rawValue: agent.agentStatus) ?? .unknown,
                    workspace: workspaces[agent.workspaceID] ?? agent.workspaceID,
                    cwd: agent.foregroundCWD ?? agent.cwd,
                    updatedAt: refreshedAt
                ))
            }
            let known = snapshot.workspaces.map {
                AgentGroup(id: $0.workspaceID, name: $0.label, agents: agentsByWorkspace[$0.workspaceID] ?? [])
            }
            let unknown = unknownWorkspaceOrder.map {
                AgentGroup(id: $0, name: $0, agents: agentsByWorkspace[$0] ?? [])
            }
            return known + unknown
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.invalidResponse(error.localizedDescription)
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func remoteCommand(arguments: [String]) -> String {
        let command = (["herdr"] + arguments).map(shellQuote).joined(separator: " ")
        return "$SHELL -lc \(shellQuote(command))"
    }

    private func run(_ source: SourceDescriptor, executable: String, arguments: [String]) throws -> Data {
        do {
            if let alias = source.sshAlias {
                return try CommandRunner.run(
                    "/usr/bin/ssh",
                    [
                        "-o", "BatchMode=yes",
                        "-o", "NumberOfPasswordPrompts=0",
                        "-o", "ConnectTimeout=4",
                        alias,
                        Self.remoteCommand(arguments: arguments),
                    ],
                    timeout: 7
                )
            }
            return try CommandRunner.run(executable, arguments)
        } catch CommandRunner.Error.timedOut {
            throw ClientError.timedOut
        } catch let CommandRunner.Error.failed(message) {
            throw ClientError.failed(message)
        }
    }

    private static func findExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["HERDR_BIN_PATH"],
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "/usr/bin/herdr",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private struct SessionList: Decodable {
    struct Session: Decodable {
        let name: String
        let running: Bool
    }

    let sessions: [Session]
}

private struct SnapshotEnvelope: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            struct Agent: Decodable {
                let agent: String?
                let agentStatus: String
                let cwd: String
                let foregroundCWD: String?
                let name: String?
                let paneID: String
                let terminalTitle: String?
                let terminalTitleStripped: String?
                let workspaceID: String

                enum CodingKeys: String, CodingKey {
                    case agent
                    case agentStatus = "agent_status"
                    case cwd
                    case foregroundCWD = "foreground_cwd"
                    case name
                    case paneID = "pane_id"
                    case terminalTitle = "terminal_title"
                    case terminalTitleStripped = "terminal_title_stripped"
                    case workspaceID = "workspace_id"
                }
            }

            struct Workspace: Decodable {
                let label: String
                let workspaceID: String

                enum CodingKeys: String, CodingKey {
                    case label
                    case workspaceID = "workspace_id"
                }
            }

            let agents: [Agent]
            let workspaces: [Workspace]
        }

        let snapshot: Snapshot
    }

    let result: Result
}
