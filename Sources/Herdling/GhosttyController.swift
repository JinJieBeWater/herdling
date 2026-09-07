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

    struct ClientMapping: Codable, Equatable, Sendable {
        let terminalID: String
        let tty: String?

        init(terminalID: String, tty: String? = nil) {
            self.terminalID = terminalID
            self.tty = tty
        }
    }

    private struct TerminalSnapshot {
        let id: String
        let name: String
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

        let key = Self.mappingKey(source: source, session: session)
        let applications = await runningApplications()
        let existing = try await reuseExistingClient(
            source: source,
            session: session,
            key: key,
            application: applications.first,
            allowAdoption: true
        )
        if existing.focused { return }

        try await ensureGhosttyRunning(existing: applications.first)
        let pendingMapping = switch openBehavior {
        case .tab:
            try await createTabOrWindow(initialInput: command)
        case .window:
            try await createWindow(initialInput: command)
        }
        let mapping = try await confirmCreatedClient(
            pendingMapping,
            source: source,
            session: session,
            excluding: existing.targetTTYs
        )
        saveMapping(mapping, forKey: key)
    }

    func focusExistingClient(
        source: SourceDescriptor = .local,
        session: String
    ) async throws -> Bool {
        guard !activationInProgress else { throw GhosttyError.operationInProgress }
        activationInProgress = true
        defer { activationInProgress = false }

        let key = Self.mappingKey(source: source, session: session)
        return try await reuseExistingClient(
            source: source,
            session: session,
            key: key,
            application: await runningApplications().first,
            allowAdoption: true
        ).focused
    }

    private func reuseExistingClient(
        source: SourceDescriptor,
        session: String,
        key: String,
        application: NSRunningApplication?,
        allowAdoption: Bool
    ) async throws -> (focused: Bool, targetTTYs: Set<String>) {
        guard let application else { return (false, []) }
        let existingMapping = loadMapping(forKey: key)
        let clients = try await Task.detached {
            try GhosttyProcessCatalog.load(ghosttyPID: Int(application.processIdentifier))
        }.value
        let targetTTYs = Set(clients.lazy.filter {
            $0.sourceID == source.id && $0.session == session
        }.map(\.tty))

        if let existingMapping,
           let terminalID = Self.reusableMappedTerminalID(
               mapping: existingMapping,
               clients: clients,
               sourceID: source.id,
               session: session
           ),
           try await focusTerminal(id: terminalID)
        {
            return (true, targetTTYs)
        }
        if existingMapping != nil { defaults.removeObject(forKey: key) }
        guard allowAdoption, !targetTTYs.isEmpty else { return (false, targetTTYs) }

        if let mapping = try await adoptExistingClient(
            source: source,
            session: session,
            clients: clients,
            preferredMapping: existingMapping
        ), try await focusTerminal(id: mapping.terminalID) {
            saveMapping(mapping, forKey: key)
            return (true, targetTTYs)
        }
        return (false, targetTTYs)
    }

    private func confirmCreatedClient(
        _ mapping: ClientMapping,
        source: SourceDescriptor,
        session: String,
        excluding existingTTYs: Set<String>
    ) async throws -> ClientMapping {
        for _ in 0..<40 {
            if let application = await runningApplications().first,
               let clients = try? await Task.detached(operation: {
                   try GhosttyProcessCatalog.load(ghosttyPID: Int(application.processIdentifier))
               }).value
            {
                let targetTTYs = Self.newClientTTYs(
                    clients: clients,
                    excluding: existingTTYs,
                    sourceID: source.id,
                    session: session
                )
                if !targetTTYs.isEmpty {
                    let terminals = try await terminalSnapshots()
                    for tty in targetTTYs where
                        try await probeTerminal(tty: tty, terminals: terminals) == mapping.terminalID
                    {
                        return ClientMapping(terminalID: mapping.terminalID, tty: tty)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw GhosttyError.clientLaunchFailed
    }

    private func createTabOrWindow(initialInput: String) async throws -> ClientMapping {
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
        return ClientMapping(terminalID: terminalID)
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
        clients: [GhosttyClientProcess],
        preferredMapping: ClientMapping?
    ) async throws -> ClientMapping? {
        let terminals = try await terminalSnapshots()
        let liveTerminalIDs = terminals.map(\.id)
        let targetTTYs = clients
            .filter { $0.sourceID == source.id && $0.session == session }
            .map(\.tty)
        var seenTTYs: Set<String> = []
        let uniqueTargetTTYs = targetTTYs.filter { seenTTYs.insert($0).inserted }
        let claimedTerminalIDs = claimedTerminalIDs(
            liveTerminalIDs: Set(liveTerminalIDs),
            excluding: preferredMapping?.terminalID
        )

        if let preferredMapping,
           preferredMapping.tty == nil,
           liveTerminalIDs.contains(preferredMapping.terminalID)
        {
            for tty in uniqueTargetTTYs {
                if try await probeTerminal(tty: tty, terminals: terminals) == preferredMapping.terminalID {
                    return ClientMapping(terminalID: preferredMapping.terminalID, tty: tty)
                }
            }
        }

        if let terminalID = Self.adoptableTerminalID(
            liveTerminalIDs: liveTerminalIDs,
            claimedTerminalIDs: claimedTerminalIDs,
            allClientTTYs: clients.map(\.tty),
            targetTTYs: targetTTYs
        ) {
            return ClientMapping(terminalID: terminalID, tty: targetTTYs.first)
        }

        for tty in uniqueTargetTTYs {
            guard let probedTerminalID = try await probeTerminal(tty: tty, terminals: terminals),
                  let terminalID = Self.adoptableTerminalID(
                  liveTerminalIDs: liveTerminalIDs,
                  claimedTerminalIDs: claimedTerminalIDs,
                  allClientTTYs: clients.map(\.tty),
                  targetTTYs: [tty],
                  probedTerminalID: probedTerminalID
              )
            else { continue }
            return ClientMapping(terminalID: terminalID, tty: tty)
        }
        return nil
    }

    private func terminalSnapshots() async throws -> [TerminalSnapshot] {
        let script = """
        tell application "Ghostty"
          set output to ""
          set fieldSeparator to ASCII character 31
          set recordSeparator to ASCII character 30
          repeat with win in windows
            repeat with tabItem in tabs of win
              repeat with term in terminals of tabItem
                set output to output & (id of term as text) & fieldSeparator & (name of term as text) & recordSeparator
              end repeat
            end repeat
          end repeat
          return output
        end tell
        """
        return try await runAppleScript(script)
            .split(separator: "\u{1e}")
            .compactMap { record in
                let fields = record.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { return nil }
                return TerminalSnapshot(id: String(fields[0]), name: String(fields[1]))
            }
    }

    private func probeTerminal(tty: String, terminals: [TerminalSnapshot]) async throws -> String? {
        guard tty.range(of: #"^ttys[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let marker = "herdling-\(UUID().uuidString)"
        do { try Self.writeTitle(marker, tty: tty) }
        catch { return nil }

        var matched: TerminalSnapshot?
        for _ in 0..<40 {
            let candidates = try await terminalSnapshots().filter { $0.name == marker }
            if candidates.count > 1 { break }
            if let candidate = candidates.first {
                matched = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        if let matched,
           let previous = terminals.first(where: { $0.id == matched.id })?.name,
           try await terminalSnapshots().first(where: { $0.id == matched.id })?.name == marker
        {
            try? Self.writeTitle(Self.safeTerminalTitle(previous), tty: tty)
        } else if matched == nil {
            try? Self.writeTitle("", tty: tty)
        }
        return matched?.id
    }

    private static func writeTitle(_ title: String, tty: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/\(tty)"))
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("\u{1b}]2;\(title)\u{7}".utf8))
    }

    private static func safeTerminalTitle(_ title: String) -> String {
        String(title.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(256))
    }

    private func claimedTerminalIDs(liveTerminalIDs: Set<String>, excluding: String?) -> Set<String> {
        Set(defaults.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix("ghostty-client."),
                  let data = value as? Data,
                  let mapping = try? JSONDecoder().decode(ClientMapping.self, from: data),
                  liveTerminalIDs.contains(mapping.terminalID),
                  mapping.terminalID != excluding
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

    nonisolated static func reusableMappedTerminalID(
        mapping: ClientMapping,
        clients: [GhosttyClientProcess],
        sourceID: String,
        session: String
    ) -> String? {
        guard let tty = mapping.tty,
              clients.contains(where: {
                  $0.tty == tty && $0.sourceID == sourceID && $0.session == session
              })
        else { return nil }
        return mapping.terminalID
    }

    nonisolated static func newClientTTYs(
        clients: [GhosttyClientProcess],
        excluding existingTTYs: Set<String>,
        sourceID: String,
        session: String
    ) -> [String] {
        var seen: Set<String> = []
        return clients.compactMap { client in
            guard client.sourceID == sourceID,
                  client.session == session,
                  !existingTTYs.contains(client.tty),
                  seen.insert(client.tty).inserted
            else { return nil }
            return client.tty
        }
    }

    nonisolated static func adoptableTerminalID(
        liveTerminalIDs: [String],
        claimedTerminalIDs: Set<String>,
        allClientTTYs: [String],
        targetTTYs: [String],
        probedTerminalID: String? = nil
    ) -> String? {
        let live = Set(liveTerminalIDs)
        let clients = Set(allClientTTYs)
        let targets = Set(targetTTYs)
        let unclaimed = live.subtracting(claimedTerminalIDs)
        if let probedTerminalID,
           targets.count == 1,
           targets.isSubset(of: clients),
           live.contains(probedTerminalID)
        {
            return probedTerminalID
        }
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
