import Foundation
import Testing
@testable import Herdling

struct KeroControllerTests {
    @Test
    func paneCanRunHerdrAsItsRootProcess() {
        let clients = KeroProcessCatalog.clients(
            from: "100 1 ttys000 /opt/homebrew/bin/herdr --session work",
            panes: [.init(id: "root", pid: 100)]
        )
        #expect(clients == [.init(paneID: "root", sourceID: "local", session: "work")])
    }

    @Test
    func catalogKeepsExactPaneSourceAndSessionWithoutAdoptingNestedTerminals() {
        let output = """
         100 1 ttys000 /bin/zsh
         101 100 ttys000 herdr
         102 101 ?? /opt/homebrew/bin/herdr server
         103 102 ttys002 /opt/homebrew/bin/herdr --session nested
         200 1 ttys021 /bin/zsh
         201 200 ttys021 /usr/bin/env wrapper
         202 201 ttys021 /opt/homebrew/bin/herdr --remote kvm --session work --remote-keybindings local
         300 1 ttys009 /opt/homebrew/bin/herdr --session unrelated
         400 1 ttys010 /opt/homebrew/bin/herdr --unknown flag
         500 501 ttys011 /opt/homebrew/bin/herdr --session cycle
         501 500 ttys011 /bin/zsh
        """
        let panes: [KeroPane] = [
            .init(id: "local", pid: 100), .init(id: "remote", pid: 200),
            .init(id: "unknown", pid: 400), .init(id: "browser", pid: nil),
            .init(id: "exited", pid: 999),
        ]
        #expect(KeroProcessCatalog.clients(from: output, panes: panes) == [
            .init(paneID: "local", sourceID: "local", session: "default"),
            .init(paneID: "remote", sourceID: "ssh:kvm", session: "work"),
        ])
    }

    @Test
    func activationReusesMatchingPaneWithoutCreatingOrTypingIntoIt() async throws {
        let cli = KeroCLIStub(sessions: matchingRoster, processes: matchingProcesses)
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        try await controller.activateClient(source: .remote("kvm"), session: "work", command: "must not run")
        #expect(try await controller.focusExistingClient(session: "default"))
        #expect(cli.focusedPanes == ["remote-pane", "local-pane"])
        #expect(cli.newArguments.isEmpty)
    }

    @Test
    func activationOpensKeroAndWaitsForItsAppConnection() async throws {
        let cli = KeroCLIStub(sessions: matchingRoster, processes: matchingProcesses, pendingFocusFailures: 2)
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        #expect(try await controller.focusExistingClient(session: "default"))
        #expect(cli.applicationArguments == [["-b", "sh.kero"]])
        #expect(cli.focusedPanes == ["local-pane"])
        #expect(cli.newArguments.isEmpty)
    }

    @Test
    func otherSourcesAndSessionsAreNotReused() async throws {
        let cli = KeroCLIStub(sessions: matchingRoster, processes: matchingProcesses)
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        #expect(try await !controller.focusExistingClient(source: .remote("other"), session: "work"))
        #expect(try await !controller.focusExistingClient(session: "work"))
        #expect(cli.focusedPanes.isEmpty)
        #expect(cli.newArguments.isEmpty)
    }

    @Test
    func newClientUsesOneShellArgumentAndFocusesItsVerifiedPane() async throws {
        let cli = KeroCLIStub(
            sessions: "[]", processes: "",
            createdSessions: #"[{"id":"created-session","panes":[{"id":"created-pane","pid":700}]}]"#,
            createdProcesses: "700 1 ttys007 /opt/homebrew/bin/herdr --remote kvm --session work"
        )
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        let command = "exec '/path with spaces/herdr' --remote 'kvm' --session 'work'"
        try await controller.activateClient(source: .remote("kvm"), session: "work", command: command)
        #expect(cli.newArguments == [[
            "new", "--name", "herdr-kvm-work", "--dir", FileManager.default.homeDirectoryForCurrentUser.path,
            "--", "/bin/zsh", "-lc", command,
        ]])
        #expect(cli.focusedPanes == ["created-pane"])
    }

    @Test
    func failedFocusDoesNotCreateADuplicateClientOrExposeCommandDetails() async throws {
        let cli = KeroCLIStub(sessions: matchingRoster, processes: matchingProcesses, failingCommand: "focus")
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        do {
            try await controller.activateClient(session: "default", command: "secret=value")
            Issue.record("Focus failure reported success")
        } catch KeroController.KeroError.commandFailed {
            #expect(cli.newArguments.isEmpty)
        }
        #expect(await controller.connectionStatus() == "Ready", "Failure releases the activation guard")
    }

    @Test(arguments: ["not json", "null", #"[{"id":"session"}]"#])
    func malformedRosterDoesNotCreateClients(response: String) async throws {
        let cli = KeroCLIStub(sessions: response, processes: "")
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        do {
            try await controller.activateClient(session: "default", command: "must not run")
            Issue.record("Invalid roster reported success")
        } catch KeroController.KeroError.invalidResponse {
            #expect(cli.newArguments.isEmpty)
            #expect(cli.focusedPanes.isEmpty)
        }
    }

    @Test
    func emptyCreationResponseDoesNotFocusAnything() async throws {
        let cli = KeroCLIStub(sessions: "[]", processes: "", createdID: "\n")
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        do {
            try await controller.activateClient(session: "default", command: "exec herdr")
            Issue.record("Empty session ID reported success")
        } catch KeroController.KeroError.invalidResponse {
            #expect(cli.focusedPanes.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func clientInAnotherSessionCannotConfirmCreation() async throws {
        let cli = KeroCLIStub(
            sessions: "[]", processes: "",
            createdSessions: #"[{"id":"other-session","panes":[{"id":"wrong-pane","pid":700}]}]"#,
            createdProcesses: "700 1 ttys007 /opt/homebrew/bin/herdr --session work"
        )
        let controller = KeroController(executable: "/fake/kero", runCommand: cli.run)
        do {
            try await controller.activateClient(session: "work", command: "exec herdr --session work")
            Issue.record("Another session's client incorrectly confirmed creation")
        } catch KeroController.KeroError.clientLaunchFailed {
            #expect(cli.focusedPanes.isEmpty)
            #expect(cli.newArguments.count == 1)
        }
    }

    @Test
    func connectionStatusReportsMissingAndUnreachableCLIWithoutRawDetails() async throws {
        #expect(await KeroController(executable: nil).connectionStatus() == "Not installed")
        let controller = KeroController(executable: "/fake/kero", runCommand: { _, _, _ in
            throw CommandRunner.Error.failed("secret=value ssh user@private-host")
        })
        #expect(await controller.connectionStatus() == "Unavailable")
        do {
            _ = try await controller.focusExistingClient(session: "default")
            Issue.record("Unreachable CLI reported success")
        } catch KeroController.KeroError.commandFailed {
            #expect(!KeroController.KeroError.commandFailed.localizedDescription.contains("secret"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func simultaneousActivationCannotCreateDuplicateClients() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); started.continuation.finish() }
        let controller = KeroController(executable: "/fake/kero", runCommand: { _, _, _ in
            started.continuation.yield(())
            _ = release.wait(timeout: .now() + 10)
            return Data("[]".utf8)
        })
        let first = Task { try await controller.focusExistingClient(session: "default") }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        do {
            try await controller.activateClient(session: "default", command: "must not run")
            Issue.record("Overlapping activation was accepted")
        } catch KeroController.KeroError.operationInProgress {}
        release.signal()
        #expect(try await !first.value)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERDLING_KERO_CATALOG_CHECK"] == "1"))
    func liveCatalogFindsCurrentHerdrClientWithoutChangingFocus() throws {
        let pane = try #require(ProcessInfo.processInfo.environment["KERO_PANE"])
        let roster = try CommandRunner.run("/opt/homebrew/bin/kero", ["ls", "--json"])
        let sessions = try JSONDecoder().decode([KeroSession].self, from: roster)
        let processes = try CommandRunner.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="])
        let clients = KeroProcessCatalog.clients(from: String(decoding: processes, as: UTF8.self), panes: sessions.flatMap(\.panes))
        #expect(clients.contains(.init(paneID: pane, sourceID: "local", session: "default")))
        print("Verified live Kero pane \(pane) → local Herdr/default without focus or session creation")
    }
}

private let matchingRoster = #"[{"id":"session","panes":[{"id":"local-pane","pid":100},{"id":"other-session-pane","pid":200},{"id":"remote-pane","pid":300},{"id":"browser-pane"}]}]"#
private let matchingProcesses = """
100 1 ttys000 /bin/zsh
101 100 ttys000 herdr
200 1 ttys001 /opt/homebrew/bin/herdr --session other
300 1 ttys002 /opt/homebrew/bin/herdr --remote kvm --session work
"""

private final class KeroCLIStub: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: String
    private var processes: String
    private let createdSessions: String?
    private let createdProcesses: String?
    private let createdID: String
    private let failingCommand: String?
    private var pendingFocusFailures: Int
    private var applications: [[String]] = []
    private var focuses: [String] = []
    private var creations: [[String]] = []

    init(sessions: String, processes: String, createdSessions: String? = nil, createdProcesses: String? = nil,
         createdID: String = "created-session", failingCommand: String? = nil, pendingFocusFailures: Int = 0) {
        self.sessions = sessions
        self.processes = processes
        self.createdSessions = createdSessions
        self.createdProcesses = createdProcesses
        self.createdID = createdID
        self.failingCommand = failingCommand
        self.pendingFocusFailures = pendingFocusFailures
    }

    var focusedPanes: [String] { lock.withLock { focuses } }
    var newArguments: [[String]] { lock.withLock { creations } }
    var applicationArguments: [[String]] { lock.withLock { applications } }

    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> Data {
        try lock.withLock {
            #expect(timeout > 0 && timeout <= 5)
            if executable == "/bin/ps" { return Data(processes.utf8) }
            if executable == "/usr/bin/open" { applications.append(arguments); return Data() }
            if arguments.first == failingCommand { throw CommandRunner.Error.failed("secret=value") }
            switch arguments.first {
            case "ls": return Data(sessions.utf8)
            case "focus":
                if pendingFocusFailures > 0 {
                    pendingFocusFailures -= 1
                    throw CommandRunner.Error.failed("kero: the app is not open")
                }
                focuses.append(arguments[1])
                return Data()
            case "new":
                creations.append(arguments)
                if let createdSessions { sessions = createdSessions }
                if let createdProcesses { processes = createdProcesses }
                return Data(createdID.utf8)
            default:
                Issue.record("Unexpected Kero command: \(arguments)")
                return Data()
            }
        }
    }
}
