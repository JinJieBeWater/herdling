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

    struct RunningSession: Sendable {
        let name: String
        let socketPath: String
    }

    private let executable: String?

    init(executable: String? = HerdrClient.findExecutable()) {
        self.executable = executable
    }

    func load(_ source: SourceDescriptor = .local) async throws -> [LoadedSession] {
        let names = try await Task.detached { try sessionNames(source) }.value
        return await withTaskGroup(of: (Int, LoadedSession).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask {
                    do {
                        return (
                            index,
                            LoadedSession(
                                name: name,
                                groups: try snapshotGroups(source, session: name),
                                error: nil
                            )
                        )
                    } catch {
                        return (
                            index,
                            LoadedSession(name: name, groups: nil, error: error.localizedDescription)
                        )
                    }
                }
            }

            var loaded = Array<LoadedSession?>(repeating: nil, count: names.count)
            for await (index, session) in group { loaded[index] = session }
            return loaded.compactMap { $0 }
        }
    }

    func sessionNames(_ source: SourceDescriptor = .local) throws -> [String] {
        guard let executable else { throw ClientError.notInstalled }
        return try Self.parseSessions(run(
            source,
            executable: executable,
            arguments: ["session", "list", "--json"]
        ))
    }

    func runningSessions(_ source: SourceDescriptor = .local) throws -> [RunningSession] {
        guard let executable else { throw ClientError.notInstalled }
        return try Self.parseRunningSessions(run(
            source,
            executable: executable,
            arguments: ["session", "list", "--json"]
        ))
    }

    func snapshotGroups(_ source: SourceDescriptor = .local, session: String) throws -> [AgentGroup] {
        guard let executable else { throw ClientError.notInstalled }
        let data = try run(
            source,
            executable: executable,
            arguments: ["--session", session, "api", "snapshot"]
        )
        return try Self.parseGroups(data)
    }

    func focus(source: SourceDescriptor = .local, session: String, paneID: String) throws {
        guard let executable else { throw ClientError.notInstalled }
        _ = try run(
            source,
            executable: executable,
            arguments: ["--session", session, "agent", "focus", paneID],
            timeout: 5
        )
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

    static func parseRunningSessions(_ data: Data) throws -> [RunningSession] {
        do {
            return try JSONDecoder().decode(SessionList.self, from: data).sessions
                .filter(\.running)
                .compactMap { session in
                    session.socketPath.map { RunningSession(name: session.name, socketPath: $0) }
                }
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
                    tabID: agent.tabID,
                    title: agent.name
                        ?? agent.displayAgent
                        ?? agent.title
                        ?? agent.terminalTitleStripped
                        ?? agent.terminalTitle
                        ?? agent.agent
                        ?? agent.paneID,
                    status: AgentStatus(rawValue: agent.agentStatus) ?? .unknown,
                    workspace: workspaces[agent.workspaceID] ?? agent.workspaceID,
                    cwd: agent.foregroundCWD ?? agent.cwd ?? "",
                    revision: agent.revision,
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
        return remoteShellCommand(command)
    }

    static func remoteShellCommand(_ command: String) -> String {
        "$SHELL -lc \(shellQuote(command))"
    }

    static func sshArguments(alias: String, command: String, keepAlive: Bool = false) -> [String] {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=4",
        ]
        if keepAlive {
            arguments += [
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
            ]
        }
        arguments += [alias, command]
        return arguments
    }

    private func run(
        _ source: SourceDescriptor,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> Data {
        do {
            if let alias = source.sshAlias {
                return try CommandRunner.run(
                    "/usr/bin/ssh",
                    Self.sshArguments(alias: alias, command: Self.remoteCommand(arguments: arguments)),
                    timeout: timeout ?? 7
                )
            }
            return try CommandRunner.run(executable, arguments, timeout: timeout ?? 5)
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
        let socketPath: String?

        enum CodingKeys: String, CodingKey {
            case name
            case running
            case socketPath = "socket_path"
        }
    }

    let sessions: [Session]
}

private struct SnapshotEnvelope: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            struct Agent: Decodable {
                let agent: String?
                let agentStatus: String
                let cwd: String?
                let displayAgent: String?
                let foregroundCWD: String?
                let name: String?
                let paneID: String
                let revision: UInt64?
                let tabID: String?
                let terminalTitle: String?
                let terminalTitleStripped: String?
                let title: String?
                let workspaceID: String

                enum CodingKeys: String, CodingKey {
                    case agent
                    case agentStatus = "agent_status"
                    case cwd
                    case displayAgent = "display_agent"
                    case foregroundCWD = "foreground_cwd"
                    case name
                    case paneID = "pane_id"
                    case revision
                    case tabID = "tab_id"
                    case terminalTitle = "terminal_title"
                    case terminalTitleStripped = "terminal_title_stripped"
                    case title
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
