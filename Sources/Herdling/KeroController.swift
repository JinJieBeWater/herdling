import Foundation

actor KeroController {
    enum KeroError: LocalizedError {
        case notInstalled
        case commandFailed
        case appNotRunning
        case invalidResponse
        case clientLaunchFailed
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Kero CLI is not installed. Install Kero or set KERO_BIN_PATH, then retry."
            case .commandFailed:
                "Kero CLI failed. Open Kero and check its CLI connection, then retry."
            case .appNotRunning:
                "Kero is not ready. Open Kero, then retry."
            case .invalidResponse:
                "Kero returned an invalid response. Update Kero, then retry."
            case .clientLaunchFailed:
                "Herdr client did not start in Kero. Check Herdr and the SSH connection, then retry."
            case .operationInProgress:
                "Another Kero action is finishing. Try again."
            }
        }
    }

    typealias CommandExecution = @Sendable (String, [String], TimeInterval) throws -> Data
    private let executable: String?
    private let runCommand: CommandExecution
    private var activationInProgress = false

    init(
        executable: String? = KeroController.findExecutable(),
        runCommand: @escaping CommandExecution = { executable, arguments, timeout in
            try CommandRunner.run(executable, arguments, timeout: timeout)
        }
    ) {
        self.executable = executable
        self.runCommand = runCommand
    }

    func connectionStatus() async -> String {
        guard executable != nil else { return "Not installed" }
        do {
            _ = try await sessions()
            return "Ready"
        } catch {
            return "Unavailable"
        }
    }

    func focusExistingClient(source: SourceDescriptor = .local, session: String) async throws -> Bool {
        guard !activationInProgress else { throw KeroError.operationInProgress }
        activationInProgress = true
        defer { activationInProgress = false }
        return try await reuseClient(source: source, session: session)
    }

    func activateClient(source: SourceDescriptor = .local, session: String, command: String) async throws {
        guard !activationInProgress else { throw KeroError.operationInProgress }
        activationInProgress = true
        defer { activationInProgress = false }
        if try await reuseClient(source: source, session: session) { return }

        let created = try await runKero([
            "new", "--name", "herdr-\(source.sshAlias ?? "local")-\(session)",
            "--dir", FileManager.default.homeDirectoryForCurrentUser.path,
            "--", "/bin/zsh", "-lc", command,
        ])
        let sessionID = String(decoding: created, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { throw KeroError.invalidResponse }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let clients = try await clients(sessionID: sessionID, deadline: deadline)
            if let client = clients.first(where: { $0.sourceID == source.id && $0.session == session }) {
                try await focusPane(client.paneID, deadline: deadline)
                return
            }
            try await Task.sleep(for: min(.milliseconds(50), max(.zero, ContinuousClock.now.duration(to: deadline))))
        }
        throw KeroError.clientLaunchFailed
    }

    private func reuseClient(source: SourceDescriptor, session: String) async throws -> Bool {
        let clients = try await clients()
        guard let client = clients.first(where: { $0.sourceID == source.id && $0.session == session }) else { return false }
        try await focusPane(client.paneID)
        return true
    }

    private func focusPane(_ paneID: String, deadline: ContinuousClock.Instant? = nil) async throws {
        let deadline = min(deadline ?? .now + .seconds(5), .now + .seconds(5))
        _ = try await run("/usr/bin/open", ["-b", "sh.kero"], deadline: deadline)
        // `kero focus` does not launch the app; wait for the launched app to connect to kerod.
        while ContinuousClock.now < deadline {
            do {
                _ = try await runKero(["focus", paneID], deadline: deadline)
                return
            } catch KeroError.appNotRunning {
                try await Task.sleep(for: min(.milliseconds(50), max(.zero, ContinuousClock.now.duration(to: deadline))))
            }
        }
        throw KeroError.appNotRunning
    }

    private func sessions(deadline: ContinuousClock.Instant? = nil) async throws -> [KeroSession] {
        let data = try await runKero(["ls", "--json"], deadline: deadline)
        do { return try JSONDecoder().decode([KeroSession].self, from: data) }
        catch { throw KeroError.invalidResponse }
    }

    private func clients(sessionID: String? = nil, deadline: ContinuousClock.Instant? = nil) async throws -> [KeroClientProcess] {
        let sessions = try await sessions(deadline: deadline)
        let panes = sessions.filter { sessionID == nil || $0.id == sessionID }.flatMap(\.panes)
        guard !panes.isEmpty else { return [] }
        let data = try await run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="], deadline: deadline)
        return KeroProcessCatalog.clients(from: String(decoding: data, as: UTF8.self), panes: panes)
    }

    private func runKero(_ arguments: [String], deadline: ContinuousClock.Instant? = nil) async throws -> Data {
        guard let executable else { throw KeroError.notInstalled }
        return try await run(executable, arguments, deadline: deadline)
    }

    private func run(_ executable: String, _ arguments: [String], deadline: ContinuousClock.Instant?) async throws -> Data {
        let timeout = try deadline.map { try Self.remainingTime(until: $0) } ?? 5
        let runCommand = runCommand
        do {
            return try await Task.detached { try runCommand(executable, arguments, timeout) }.value
        } catch CommandRunner.Error.failed(let message) where executable == self.executable && message.contains("the app is not open") {
            throw KeroError.appNotRunning
        } catch {
            // CLI errors can echo SSH details or the launch command.
            throw KeroError.commandFailed
        }
    }

    private static func remainingTime(until deadline: ContinuousClock.Instant) throws -> TimeInterval {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw KeroError.clientLaunchFailed }
        return min(5, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
    }

    private static func findExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["KERO_BIN_PATH"],
            "/opt/homebrew/bin/kero",
            "/usr/local/bin/kero",
            "/Applications/Kero.app/Contents/MacOS/Kero",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Kero.app/Contents/MacOS/Kero").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
