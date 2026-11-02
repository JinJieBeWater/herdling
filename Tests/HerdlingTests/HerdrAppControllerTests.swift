import Darwin
import Foundation
import Testing
@testable import Herdling

struct HerdrAppControllerTests {
    @Test
    func snapshotUsesAppSeenStatesAndKeepsUnreportedAndUnknownDistinct() async throws {
        let fixture = NativeAppFixture(world: appWorld([
            appTerminal("t7", status: "idle"), appTerminal("box/t7", pane: "remote-pane", status: "done"),
            appTerminal("t8", pane: "unreported", status: nil), appTerminal("t9", pane: "future", status: "future")
        ]))
        let snapshot = try await fixture.controller().snapshot(entryCoreID: "entry-A")
        #expect(snapshot.entryCoreID == "entry-A")
        #expect(snapshot.terminals.map(\.address) == ["t7", "box/t7", "t8", "t9"])
        #expect(snapshot.terminals.map(\.status) == [.idle, .done, nil, .unknown])
        #expect(fixture.requests.allSatisfy { $0["ls"] as? Bool == true })
        #expect(fixture.launchEnvironments.isEmpty)
        #expect(fixture.proofCalls == 2)
    }

    @Test
    func oneReplySocketMayCloseWithoutInvalidatingItsCapturedProcessProof() async throws {
        let fixture = NativeAppFixture()
        fixture.closePeerAfterReply = true
        let snapshot = try await fixture.controller().snapshot(entryCoreID: "entry-A")
        #expect(snapshot.terminals.map(\.address) == ["t7"])
        #expect(fixture.proofCalls == 2)
    }

    @Test(arguments: ["working", "idle", "blocked", "done"])
    func focusUsesNativePaneAndRaisesThenReadsBackExactDestination(status: String) async throws {
        let fixture = NativeAppFixture(world: appWorld([appTerminal("t7", status: status)]))
        try await fixture.controller().focus(target: fixture.target)
        let focus = try #require(fixture.requests.first { $0["do"] as? String == "pane.focus" })
        #expect((focus["args"] as? [String: String]) == ["pane": "pane-7"])
        #expect(fixture.requests.contains { $0["raise"] as? Bool == true })
        #expect(fixture.requests.contains { $0["status"] as? Bool == true })
        #expect(fixture.requests.allSatisfy { $0["do"] == nil || $0["do"] as? String == "pane.focus" })
        #expect(fixture.proofCalls >= fixture.requests.count * 2)
        #expect(fixture.launchEnvironments.isEmpty)
    }

    @Test
    func remoteFocusKeepsEntryCoreAndHostingCoreSeparate() async throws {
        let fixture = NativeAppFixture(world: appWorld([appTerminal("box/t7", status: "working")]))
        fixture.address = "box/t7"
        fixture.hostingCoreID = "remote-B"
        try await fixture.controller().focus(target: fixture.target)
        #expect(fixture.requests.contains { $0["do"] as? String == "pane.focus" })
    }

    @Test(arguments: ["core identity", "core peer", "app peer", "native proof", "changed connection"])
    func matchingShortTerminalCannotBypassCoreAndProcessProof(failure: String) async throws {
        let fixture = NativeAppFixture()
        switch failure {
        case "core identity": fixture.coreID = "entry-other"
        case "core peer": fixture.corePID = nil
        case "app peer": fixture.appPID = nil
        case "native proof": fixture.rejectProof = true
        case "changed connection": fixture.changeProofAt = 2
        default: break
        }
        await #expect(throws: HerdrAppError.identityUnverified) {
            try await fixture.controller().snapshot(entryCoreID: "entry-A")
        }
        #expect(fixture.requests.allSatisfy { $0["ls"] as? Bool == true })
    }

    @Test(arguments: [
        appWorld([appTerminal("t7"), appTerminal("t7", pane: "second")]),
        appWorld([appTerminal("t7"), appTerminal("t8")]),
        appWorld([appTerminal("invalid-address")]),
        #"{"spaces":[{"id":"same","active":true,"tabs":[{"id":"same","active":true,"terminals":[]}]}]}"#,
        #"{"spaces":[{"id":"space-A","active":true,"tabs":[{"id":"tab-A","active":true,"terminals":[{"terminal":"t7","pane":"","status":"idle"}]}]}]}"#,
        #"{"spaces":null}"#
    ])
    func malformedOrAmbiguousAppDirectoryIsRejected(world: String) async throws {
        let fixture = NativeAppFixture(world: world)
        await #expect(throws: HerdrAppError.invalidResponse) {
            try await fixture.controller().snapshot(entryCoreID: "entry-A")
        }
    }

    @Test
    func missingPaneFailsWithoutKeepingOrChangingLabels() async throws {
        let fixture = NativeAppFixture(world: appWorld([appTerminal("t8")]))
        await #expect(throws: HerdrAppError.missingPane) { try await fixture.controller().focus(target: fixture.target) }
        #expect(fixture.requests.count == 1)
        #expect(try #require(fixture.requests.first)["ls"] as? Bool == true)
    }

    @Test(arguments: ["space", "tab", "focused_pane", "agent", "null pane", "inactive"])
    func focusRejectsWrongOrUnconfirmedDestination(field: String) async throws {
        let fixture = NativeAppFixture()
        if field == "inactive" { fixture.world = fixture.world.replacingOccurrences(of: "\"active\":true", with: "\"active\":false") }
        else { fixture.statusOverride = (field == "null pane" ? "focused_pane" : field, field == "null pane" ? nil : "other") }
        await #expect(throws: HerdrAppError.destinationUnverified) {
            try await fixture.controller().focus(target: fixture.target)
        }
    }

    @Test
    func raiseWithoutActualForegroundIsNotSuccessfulNavigation() async throws {
        let fixture = NativeAppFixture()
        fixture.foreground = false
        await #expect(throws: HerdrAppError.notForeground) { try await fixture.controller().focus(target: fixture.target) }
    }

    @Test
    func appSwitchingCoreBetweenFocusAndRaiseStopsFurtherCommands() async throws {
        let fixture = NativeAppFixture()
        fixture.changeProofAt = 5
        await #expect(throws: HerdrAppError.identityUnverified) { try await fixture.controller().focus(target: fixture.target) }
        #expect(fixture.requests.contains { $0["do"] as? String == "pane.focus" })
        #expect(!fixture.requests.contains { $0["raise"] != nil })
    }

    @Test
    func observationNeverLaunchesAndExistingUnavailableAppIsNotRestarted() async throws {
        let fixture = NativeAppFixture()
        fixture.available = false
        fixture.running = true
        let controller = fixture.controller()
        await #expect(throws: HerdrAppError.unavailable) { try await controller.snapshot(entryCoreID: "entry-A") }
        await #expect(throws: HerdrAppError.unavailable) { try await controller.focus(target: fixture.target) }
        #expect(fixture.launchEnvironments.isEmpty)
    }

    @Test
    func explicitFocusLaunchesOnlyClosedAppWithChosenEndpointsAndClearedCallerContext() async throws {
        let fixture = NativeAppFixture()
        fixture.available = false
        try await fixture.controller(environment: [
            "HERDR_APP_HOME": "/fixture-app", "HC_CALLER": "stale", "HC_TERMINAL_ID": "t9", "HERDR_PANE_ID": "old", "PATH": "/usr/bin:/bin"
        ]).focus(target: fixture.target)
        try #require(fixture.launchEnvironments.count == 1)
        let environment = try #require(fixture.launchEnvironments.first)
        #expect(environment["HC_SOCKET"] == "/fixture-core.sock")
        #expect(environment["HERDR_APP_HOME"] == "/fixture-app")
        #expect(environment["HC_CALLER"] == nil && environment["HC_TERMINAL_ID"] == nil && environment["HERDR_PANE_ID"] == nil)
        #expect(fixture.paths.allSatisfy { $0 == "/fixture-app/herdr-app.sock" })
    }

    @Test
    func endpointPathsFollowNativeAppOverridesAndRejectInvalidPaths() throws {
        let home = URL(fileURLWithPath: "/fixture-home")
        #expect(try HerdrAppController.home(environment: [:], homeDirectory: home) == "/fixture-home/.config/herdr-app")
        #expect(try HerdrAppController.home(environment: ["XDG_CONFIG_HOME": "/config"], homeDirectory: home) == "/config/herdr-app")
        #expect(try HerdrAppController.home(environment: ["XDG_CONFIG_HOME": "/config", "HERDR_APP_HOME": "/app"], homeDirectory: home) == "/app")
        for environment in [["HERDR_APP_HOME": "relative"], ["HERDR_APP_HOME": "/a\0b"], ["XDG_CONFIG_HOME": "relative"], ["HERDR_APP_HOME": "/" + String(repeating: "x", count: 104)]] {
            #expect(throws: HerdrAppError.invalidConfiguration) { try HerdrAppController.home(environment: environment, homeDirectory: home) }
        }
    }

    @Test
    func appErrorsAreSanitizedAndNoCoreRawFallbackIsInvented() async throws {
        let fixture = NativeAppFixture(world: #"{"error":"private environment and path"}"#)
        await #expect(throws: HerdrAppError.commandFailed) { try await fixture.controller().snapshot(entryCoreID: "entry-A") }
        #expect(HerdrAppError.commandFailed.localizedDescription.contains("private environment") == false)
    }
}

private func appTerminal(_ address: String, pane: String = "pane-7", status: String? = "done") -> String {
    let value = status.map { "\"\($0)\"" } ?? "null"
    return "{\"terminal\":\"\(address)\",\"pane\":\"\(pane)\",\"status\":\(value),\"sub_agents\":[],\"extra\":true}"
}

private func appWorld(_ terminals: [String]) -> String {
    "{\"spaces\":[{\"id\":\"space-A\",\"active\":true,\"tabs\":[{\"id\":\"tab-A\",\"active\":true,\"terminals\":[\(terminals.joined(separator: ","))]}]}]}"
}

private final class NativeAppFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private var launched: [[String: String]] = []
    private var recordedPaths: [String] = []
    private var proofs = 0
    var world: String
    var coreID = "entry-A"
    var corePID: Int32? = 900
    var appPID: Int32? = 901
    var closePeerAfterReply = false
    var address = "t7"
    var hostingCoreID = "entry-A"
    var rejectProof = false
    var changeProofAt: Int?
    var statusOverride: (String, String?)?
    var foreground = true
    var available = true
    var running = false

    init(world: String = appWorld([appTerminal("t7")])) { self.world = world }
    var requests: [[String: Any]] { lock.withLock { recorded } }
    var launchEnvironments: [[String: String]] { lock.withLock { launched } }
    var paths: [String] { lock.withLock { recordedPaths } }
    var proofCalls: Int { lock.withLock { proofs } }
    var target: CoreTerminalTarget {
        .init(id: .init(coreID: hostingCoreID, terminalID: "t7"), socketPath: "/fixture-core.sock", entryCoreID: "entry-A", address: address)
    }

    func controller(environment: [String: String] = ["HERDR_APP_HOME": "/fixture-app"]) -> HerdrAppController {
        HerdrAppController(
            coreClient: .init(socketPath: target.socketPath, transportFactory: { _ in
                AppFixtureTransport(peerPID: self.corePID) { data in try self.coreResponse(data) }
            }),
            environment: environment,
            transportFactory: { path in
                self.lock.withLock { self.recordedPaths.append(path) }
                guard self.available else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
                return AppFixtureTransport(peerPID: self.appPID, closePeerAfterReply: self.closePeerAfterReply) { data in try self.appResponse(data) }
            },
            nativeProof: { app, core in
                let count = self.lock.withLock { self.proofs += 1; return self.proofs }
                guard !self.rejectProof, app == 901, core == 900 else { throw HerdrAppError.identityUnverified }
                let connection: Int32 = count >= (self.changeProofAt ?? Int.max) ? 903 : 902
                return HerdrAppProcessBinding(appProcessID: app, coreProcessID: core, connectionProcessID: connection,
                                              appStarted: 1, coreStarted: 2, connectionStarted: 3)
            },
            isForeground: { _ in self.foreground }, isRunning: { self.running },
            launch: { environment in
                self.lock.withLock { self.launched.append(environment) }
                self.available = true
            }
        )
    }

    private func appResponse(_ data: Data) throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        lock.withLock { recorded.append(request) }
        if request["ls"] != nil { return Data(world.utf8) }
        if request["status"] != nil {
            var status: [String: Any] = ["space": "space-A", "tab": "tab-A", "focused_pane": "pane-7", "agent": address]
            if let (field, value) = statusOverride { status[field] = value.map { $0 as Any } ?? NSNull() }
            return try JSONSerialization.data(withJSONObject: status)
        }
        if request["raise"] != nil || request["do"] as? String == "pane.focus" { return Data(#"{"ok":true}"#.utf8) }
        throw HerdrAppError.commandFailed
    }

    private func coreResponse(_ data: Data) throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try #require(request["id"] as? String)
        let result: [String: Any]
        switch request["method"] as? String {
        case "hello": result = ["generation": 1, "core": ["id": coreID, "name": "fixture"]]
        case "terminal.get": result = ["address": address, "cwd": "/fixture", "state": "live", "pid": 42]
        case "machine.list": result = ["machines": [["name": "box", "id": "remote-B", "target": "fixture", "state": "connected"]]]
        default: throw HerdrAppError.coreUnavailable
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }
}

private final class AppFixtureTransport: HerdrCoreTransport, @unchecked Sendable {
    private let peerPID: Int32?
    private let closePeerAfterReply: Bool
    private var hasRead = false
    var peerProcessID: Int32? { hasRead && closePeerAfterReply ? nil : peerPID }
    private let response: (Data) throws -> Data
    private var pending: Data?

    init(peerPID: Int32?, closePeerAfterReply: Bool = false, response: @escaping (Data) throws -> Data) {
        self.peerPID = peerPID
        self.closePeerAfterReply = closePeerAfterReply
        self.response = response
    }
    func write(_ line: Data) throws { pending = try response(line) }
    func readLine(timeout: TimeInterval) throws -> Data? { defer { pending = nil; hasRead = true }; return pending }
    func close() { }
}
