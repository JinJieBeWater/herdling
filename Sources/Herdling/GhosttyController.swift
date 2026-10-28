import AppKit
import Foundation

enum GhosttyOpenBehavior: String, CaseIterable, Sendable {
    case window
    case tab
}

actor GhosttyController {
    enum GhosttyError: LocalizedError {
        case notInstalled
        case automationFailed(String)
        case clientCreationFailed
        case clientLaunchFailed
        case clientMatchFailed
        case operationInProgress

        var isAutomationPermissionDenied: Bool {
            guard case let .automationFailed(message) = self else { return false }
            let normalized = message.lowercased()
            return normalized.contains("-1743") || normalized.contains("not authorized to send apple events")
        }

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Ghostty is not installed. Install Ghostty, then retry."
            case let .automationFailed(message):
                isAutomationPermissionDenied
                    ? "Ghostty Automation denied. Allow Herdling in System Settings → Privacy & Security → Automation."
                    : Self.automationFailureDescription(message)
            case .clientCreationFailed:
                "Ghostty did not create a usable terminal. Try again or switch new clients to Window in Settings."
            case .clientLaunchFailed:
                "Herdr client did not start in Ghostty. Check Herdr and the SSH connection, then retry."
            case .clientMatchFailed:
                "Ghostty terminal identity could not be verified. Update Ghostty to 1.4 or later, then retry."
            case .operationInProgress:
                "Another Ghostty action is finishing. Try again."
            }
        }

        static func automationFailureDescription(_ message: String) -> String {
            let message = message.lowercased()
            if message.contains("new_tab") {
                return "Ghostty could not open a new tab. Switch new clients to Window in Settings, then retry."
            }
            if message.contains("timed out") || message.contains("timeout") {
                return "Ghostty Automation timed out. Open Ghostty, then retry."
            }
            return "Ghostty Automation failed. Check Automation permission in System Settings, then retry."
        }
    }

    private struct TerminalSnapshot: Sendable {
        let id: String
        let tty: String?
    }

    private let executeScript: @Sendable (String, TimeInterval) throws -> String
    private let runningPID: @Sendable () async -> Int?
    private let loadClients: @Sendable (Int, TimeInterval) throws -> [GhosttyClientProcess]
    private var activationInProgress = false

    init(
        executeScript: @escaping @Sendable (String, TimeInterval) throws -> String = { script, timeout in
            let data = try CommandRunner.run("/usr/bin/osascript", ["-e", script], timeout: timeout)
            return String(decoding: data, as: UTF8.self)
        },
        runningPID: @escaping @Sendable () async -> Int? = {
            await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
                    .first.map { Int($0.processIdentifier) }
            }
        },
        loadClients: @escaping @Sendable (Int, TimeInterval) throws -> [GhosttyClientProcess] = {
            try GhosttyProcessCatalog.load(ghosttyPID: $0, timeout: $1)
        }
    ) {
        self.executeScript = executeScript
        self.runningPID = runningPID
        self.loadClients = loadClients
    }

    func automationPermissionStatus() async -> String {
        guard await runningPID() != nil else { return "Ghostty not running" }
        do {
            _ = try await runAppleScript("tell application \"Ghostty\" to return count of windows as text")
            return "Allowed"
        } catch {
            return Self.automationPermissionFailureStatus(error)
        }
    }

    nonisolated static func automationPermissionFailureStatus(_ error: Error) -> String {
        (error as? GhosttyError)?.isAutomationPermissionDenied == true ? "Denied" : "Unavailable"
    }

    func activateClient(
        source: SourceDescriptor = .local,
        session: String,
        command: String,
        openBehavior: GhosttyOpenBehavior
    ) async throws {
        guard !activationInProgress else { throw GhosttyError.operationInProgress }
        activationInProgress = true
        defer { activationInProgress = false }

        let pid = await runningPID()
        let existing = try await reuseExistingClient(
            source: source,
            session: session,
            pid: pid
        )
        if existing { return }

        try await ensureGhosttyRunning(existing: pid)
        let terminalID = switch openBehavior {
        case .tab:
            try await createTabOrWindow(initialInput: command)
        case .window:
            try await createWindow(initialInput: command)
        }
        try await confirmCreatedClient(
            terminalID,
            source: source,
            session: session
        )
    }

    func focusExistingClient(
        source: SourceDescriptor = .local,
        session: String
    ) async throws -> Bool {
        guard !activationInProgress else { throw GhosttyError.operationInProgress }
        activationInProgress = true
        defer { activationInProgress = false }

        return try await reuseExistingClient(
            source: source,
            session: session,
            pid: await runningPID()
        )
    }

    private func reuseExistingClient(
        source: SourceDescriptor,
        session: String,
        pid: Int?
    ) async throws -> Bool {
        guard let pid else { return false }
        let clients = try await clients(pid: pid)
        let terminals = try await terminalSnapshots()
        let matches = try Self.matchingTerminals(
            clients: clients, terminals: terminals, sourceID: source.id, session: session
        )
        guard let terminal = matches.first else {
            return false
        }
        guard try await focusTerminal(id: terminal.id) else { throw GhosttyError.clientMatchFailed }
        return true
    }

    private func clients(pid: Int, deadline: ContinuousClock.Instant? = nil) async throws -> [GhosttyClientProcess] {
        let loadClients = loadClients
        let timeout = try deadline.map { try Self.remainingTime(until: $0, maximum: 1) } ?? 1
        return try await Task.detached { try loadClients(pid, timeout) }.value
    }

    private func confirmCreatedClient(
        _ terminalID: String,
        source: SourceDescriptor,
        session: String
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let pid = await runningPID(),
               let clients = try? await clients(pid: pid, deadline: deadline) {
                let terminals = try await terminalSnapshots(deadline: deadline)
                // Native TTY publication and client startup can finish on different polls.
                let matches = (try? Self.matchingTerminals(
                    clients: clients, terminals: terminals, sourceID: source.id, session: session
                )) ?? []
                if matches.contains(where: { $0.id == terminalID }), ContinuousClock.now < deadline {
                    return
                }
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            try await Task.sleep(for: min(.milliseconds(50), remaining))
        }
        throw GhosttyError.clientLaunchFailed
    }

    private static func matchingTerminals(
        clients: [GhosttyClientProcess],
        terminals: [TerminalSnapshot],
        sourceID: String,
        session: String
    ) throws -> [TerminalSnapshot] {
        let targets = clients.filter { $0.sourceID == sourceID && $0.session == session }
        guard Set(terminals.map(\.id)).count == terminals.count,
              terminals.allSatisfy({ $0.tty != nil }),
              Set(terminals.compactMap(\.tty)).count == terminals.count
        else { throw GhosttyError.clientMatchFailed }
        return try targets.map { client in
            guard let tty = GhosttyProcessCatalog.normalizedTTY(client.tty),
                  clients.filter({ GhosttyProcessCatalog.normalizedTTY($0.tty) == tty }).count == 1
            else { throw GhosttyError.clientMatchFailed }
            let matches = terminals.filter { $0.tty == tty }
            guard matches.count == 1, let terminal = matches.first else { throw GhosttyError.clientMatchFailed }
            return terminal
        }
    }

    nonisolated static func remainingTime(until deadline: ContinuousClock.Instant, maximum: TimeInterval) throws -> TimeInterval {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw GhosttyError.clientLaunchFailed }
        return min(maximum, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
    }

    private func createTabOrWindow(initialInput: String) async throws -> String {
        let windowInput = initialInput.hasSuffix("\n") ? initialInput : initialInput + "\n"
        let script = """
        tell application "Ghostty"
          if (count of windows) is 0 then
            set cfg to new surface configuration
            set initial input of cfg to \(Self.appleScriptString(windowInput))
            set win to new window with configuration cfg
            set term to terminal 1 of selected tab of win
            return id of term as text
          end if
          set anchorID to id of focused terminal of selected tab of front window as text
          if not (perform action "new_tab" on terminal id anchorID) then error "Ghostty rejected action new_tab."
          set terminalID to missing value
          repeat 80 times
            set term to focused terminal of selected tab of front window
            if (id of term as text) is not anchorID then
              try
                input text "" to term
                set terminalID to id of term as text
                exit repeat
              end try
            end if
            delay 0.025
          end repeat
          if terminalID is missing value then error "Ghostty did not return a writable tab."
          input text \(Self.appleScriptString(initialInput)) to terminal id terminalID
          send key "enter" to terminal id terminalID
          return terminalID
        end tell
        """
        let terminalID = try await runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terminalID.isEmpty else { throw GhosttyError.clientCreationFailed }
        return terminalID
    }

    private func createWindow(initialInput: String) async throws -> String {
        let input = initialInput.hasSuffix("\n") ? initialInput : initialInput + "\n"
        let script = """
        tell application "Ghostty"
          set cfg to new surface configuration
          set initial input of cfg to \(Self.appleScriptString(input))
          set win to new window with configuration cfg
          set term to terminal 1 of selected tab of win
          return id of term as text
        end tell
        """
        let terminalID = try await runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terminalID.isEmpty else { throw GhosttyError.clientCreationFailed }
        return terminalID
    }

    private func focusTerminal(id: String) async throws -> Bool {
        let value = Self.appleScriptString(id)
        let script = """
        tell application "Ghostty"
          focus terminal id \(value)
          activate
          return "focused"
        end tell
        """
        return try await runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines) == "focused"
    }

    private func terminalSnapshots(deadline: ContinuousClock.Instant? = nil) async throws -> [TerminalSnapshot] {
        let script = """
        tell application "Ghostty"
          set output to ""
          set fieldSeparator to ASCII character 31
          set recordSeparator to ASCII character 30
          repeat with term in every terminal
            set output to output & (id of term as text) & fieldSeparator & (tty of term as text) & recordSeparator
          end repeat
          return output
        end tell
        """
        return try await runAppleScript(script, deadline: deadline)
            .trimmingCharacters(in: .newlines)
            .split(separator: "\u{1e}")
            .map { record in
                let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard fields.count == 2, !fields[0].isEmpty else { throw GhosttyError.clientMatchFailed }
                return TerminalSnapshot(id: String(fields[0]), tty: GhosttyProcessCatalog.normalizedTTY(String(fields[1])))
            }
    }

    private func runAppleScript(_ script: String, deadline: ContinuousClock.Instant? = nil) async throws -> String {
        let executeScript = executeScript
        do {
            return try await Task.detached {
                let timeout = try deadline.map { try Self.remainingTime(until: $0, maximum: 5) } ?? 5
                return try executeScript(script, timeout)
            }.value
        } catch GhosttyError.clientLaunchFailed {
            throw GhosttyError.clientLaunchFailed
        } catch {
            throw GhosttyError.automationFailed(error.localizedDescription)
        }
    }

    private func ensureGhosttyRunning(existing: Int?) async throws {
        if existing != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
                    continuation.resume(throwing: GhosttyError.notInstalled)
                    return
                }
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { application, error in
                    if application != nil { continuation.resume() }
                    else { continuation.resume(throwing: error ?? GhosttyError.notInstalled) }
                }
            }
        }
    }

    static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
