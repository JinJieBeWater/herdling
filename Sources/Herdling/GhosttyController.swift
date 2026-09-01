import AppKit
import Foundation

actor GhosttyController {
    enum GhosttyError: LocalizedError {
        case notInstalled
        case automationFailed(String)
        case clientCreationFailed
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Ghostty is not installed."
            case let .automationFailed(message):
                message.isEmpty ? "Ghostty automation failed." : message
            case .clientCreationFailed:
                "Ghostty did not return a client terminal."
            case .operationInProgress:
                "Another Ghostty focus operation is still running."
            }
        }
    }

    struct ClientMapping: Codable, Equatable, Sendable {
        let terminalID: String
    }

    private let defaults: UserDefaults
    private var activationInProgress = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func automationPermissionStatus() async -> String {
        guard !(await runningApplications()).isEmpty else { return "Ghostty not running" }
        do {
            _ = try await runAppleScript("tell application \"Ghostty\" to return count of windows as text")
            return "Allowed"
        } catch {
            return error.localizedDescription.contains("-1743") ? "Denied" : "Unavailable"
        }
    }

    func activateClient(
        source: SourceDescriptor = .local,
        session: String,
        command: String
    ) async throws {
        guard !activationInProgress else { throw GhosttyError.operationInProgress }
        activationInProgress = true
        defer { activationInProgress = false }

        let key = Self.mappingKey(source: source, session: session)
        let applications = await runningApplications()
        if let mapping = loadMapping(forKey: key), !applications.isEmpty {
            if try await focusTerminal(id: mapping.terminalID) {
                return
            }
            defaults.removeObject(forKey: key)
        }

        if let application = applications.first,
           let mapping = try await adoptExistingClient(
               source: source,
               session: session,
               ghosttyPID: Int(application.processIdentifier)
           ),
           try await focusTerminal(id: mapping.terminalID)
        {
            saveMapping(mapping, forKey: key)
            return
        }

        try await ensureGhosttyRunning(existing: applications.first)
        let mapping = try await createWindow(initialInput: command)
        saveMapping(mapping, forKey: key)
    }

    private func createWindow(initialInput: String) async throws -> ClientMapping {
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
        return ClientMapping(terminalID: terminalID)
    }

    private func focusTerminal(id: String) async throws -> Bool {
        let value = Self.appleScriptString(id)
        let script = """
        tell application "Ghostty"
          try
            focus terminal id \(value)
            activate
            return "focused"
          on error
            return "missing"
          end try
        end tell
        """
        return try await runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines) == "focused"
    }

    private func adoptExistingClient(
        source: SourceDescriptor,
        session: String,
        ghosttyPID: Int
    ) async throws -> ClientMapping? {
        let liveTerminalIDs = try await terminalIDs()
        let clients = try await Task.detached {
            try GhosttyProcessCatalog.load(ghosttyPID: ghosttyPID)
        }.value
        let targetTTYs = clients
            .filter { $0.sourceID == source.id && $0.session == session }
            .map(\.tty)
        let claimedTerminalIDs = claimedTerminalIDs(liveTerminalIDs: Set(liveTerminalIDs))
        guard let terminalID = Self.adoptableTerminalID(
            liveTerminalIDs: liveTerminalIDs,
            claimedTerminalIDs: claimedTerminalIDs,
            allClientTTYs: clients.map(\.tty),
            targetTTYs: targetTTYs
        ) else { return nil }
        return ClientMapping(terminalID: terminalID)
    }

    private func terminalIDs() async throws -> [String] {
        let script = """
        tell application "Ghostty"
          set output to ""
          repeat with win in windows
            repeat with tabItem in tabs of win
              repeat with term in terminals of tabItem
                set output to output & (id of term as text) & linefeed
              end repeat
            end repeat
          end repeat
          return output
        end tell
        """
        return try await runAppleScript(script)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    private func claimedTerminalIDs(liveTerminalIDs: Set<String>) -> Set<String> {
        Set(defaults.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix("ghostty-client."),
                  let data = value as? Data,
                  let mapping = try? JSONDecoder().decode(ClientMapping.self, from: data),
                  liveTerminalIDs.contains(mapping.terminalID)
            else { return nil }
            return mapping.terminalID
        })
    }

    private func runAppleScript(_ script: String) async throws -> String {
        do {
            let data = try await Task.detached {
                try CommandRunner.run("/usr/bin/osascript", ["-e", script], timeout: 5)
            }.value
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw GhosttyError.automationFailed(error.localizedDescription)
        }
    }

    private func runningApplications() async -> [NSRunningApplication] {
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
        }
    }

    private func ensureGhosttyRunning(existing: NSRunningApplication?) async throws {
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

    static func mappingKey(source: SourceDescriptor, session: String) -> String {
        "ghostty-client.\(source.id.utf8.count):\(source.id):\(session.utf8.count):\(session)"
    }

    nonisolated static func adoptableTerminalID(
        liveTerminalIDs: [String],
        claimedTerminalIDs: Set<String>,
        allClientTTYs: [String],
        targetTTYs: [String]
    ) -> String? {
        let live = Set(liveTerminalIDs)
        let clients = Set(allClientTTYs)
        let targets = Set(targetTTYs)
        let unclaimed = live.subtracting(claimedTerminalIDs)
        guard live.count == clients.count,
              targets.count == 1,
              unclaimed.count == 1
        else { return nil }
        return unclaimed.first
    }

    private func loadMapping(forKey key: String) -> ClientMapping? {
        guard let data = defaults.data(forKey: key),
              let mapping = try? JSONDecoder().decode(ClientMapping.self, from: data)
        else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return mapping
    }

    private func saveMapping(_ mapping: ClientMapping, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(mapping), forKey: key)
    }

    static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
