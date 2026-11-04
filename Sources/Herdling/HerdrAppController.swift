import AppKit
import Darwin
import Foundation

struct HerdrAppTerminal: Equatable, Sendable {
    let address: String
    let status: AgentStatus?
    let paneID: String
    let spaceID: String
    let tabID: String
}

struct HerdrAppSnapshot: Equatable, Sendable {
    let entryCoreID: String
    let terminals: [HerdrAppTerminal]
}

enum HerdrAppError: LocalizedError, Equatable {
    case unavailable, invalidConfiguration, identityUnverified, coreUnavailable, invalidResponse
    case missingPane, commandFailed, destinationUnverified, notForeground, launchFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Herdr App is not running or its control socket is unavailable."
        case .invalidConfiguration: "The Herdr App control endpoint is invalid."
        case .identityUnverified: "Herdr App could not be verified as connected to this Core."
        case .coreUnavailable: "The selected Core terminal is unavailable. Refresh and retry."
        case .invalidResponse: "Herdr App returned an invalid control response."
        case .missingPane: "This terminal has no existing Herdr App pane. Open it in Herdr App, then retry."
        case .commandFailed: "Herdr App could not complete the control request."
        case .destinationUnverified: "Herdr App did not confirm the selected space, tab and terminal."
        case .notForeground: "Herdr App did not become the foreground application."
        case .launchFailed: "Herdr App could not be launched. Install Herdr App and retry."
        }
    }
}

actor HerdrAppController {
    typealias NativeProof = @Sendable (Int32, Int32) throws -> HerdrAppProcessBinding
    typealias ForegroundCheck = @Sendable (Int32) async -> Bool
    typealias RunningCheck = @Sendable () async -> Bool
    typealias Launcher = @Sendable ([String: String]) async throws -> Void

    private let coreClient: HerdrCoreClient
    private let appHome: String?
    private let environment: [String: String]
    private let transportFactory: HerdrCoreClient.TransportFactory
    private let nativeProof: NativeProof
    private let isForeground: ForegroundCheck
    private let isRunning: RunningCheck
    private let launch: Launcher

    init(
        coreClient: HerdrCoreClient,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        transportFactory: @escaping HerdrCoreClient.TransportFactory = { try HerdrCoreSocket(path: $0) },
        nativeProof: @escaping NativeProof = { try HerdrAppProcessBinding.verify(appProcessID: $0, coreProcessID: $1) },
        isForeground: @escaping ForegroundCheck = { pid in
            await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                    && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "dev.herdr.app"
            }
        },
        isRunning: @escaping RunningCheck = {
            await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.herdr.app").isEmpty }
        },
        launch: @escaping Launcher = { environment in try await HerdrAppController.launchApplication(environment: environment) }
    ) {
        self.coreClient = coreClient
        self.environment = environment
        appHome = try? Self.home(environment: environment, homeDirectory: homeDirectory)
        self.transportFactory = transportFactory
        self.nativeProof = nativeProof
        self.isForeground = isForeground
        self.isRunning = isRunning
        self.launch = launch
    }

    func snapshot(entryCoreID: String) async throws -> HerdrAppSnapshot {
        try Task.checkCancellation()
        let core = try connectCore(entryCoreID: entryCoreID)
        defer { core.close() }
        let (world, _) = try request(World.self, command: ["ls": true], core: core)
        return HerdrAppSnapshot(entryCoreID: entryCoreID, terminals: try world.terminals())
    }

    func focus(target: CoreTerminalTarget) async throws {
        try Task.checkCancellation()
        do { try coreClient.validate(target) }
        catch { throw HerdrAppError.coreUnavailable }
        let core = try connectCore(entryCoreID: target.entryCoreID)
        defer { core.close() }
        let initial: (World, HerdrAppProcessBinding)
        do { initial = try request(World.self, command: ["ls": true], core: core) }
        catch HerdrAppError.unavailable {
            guard !(await isRunning()) else { throw HerdrAppError.unavailable }
            try await launchApp()
            initial = try await waitForApp(core: core)
        }
        let (world, binding) = initial
        guard let destination = try world.terminals().first(where: { $0.address == target.address }) else {
            throw HerdrAppError.missingPane
        }
        do { try coreClient.validate(target) }
        catch { throw HerdrAppError.coreUnavailable }
        _ = try request(Acknowledgement.self, command: ["do": "pane.focus", "args": ["pane": destination.paneID]], core: core, expected: binding)
        _ = try request(Acknowledgement.self, command: ["raise": true], core: core, expected: binding)
        let deadline = Date().addingTimeInterval(2)
        var failure = HerdrAppError.destinationUnverified
        repeat {
            try Task.checkCancellation()
            let (status, _) = try request(WindowStatus.self, command: ["status": true], core: core, expected: binding)
            let (current, _) = try request(World.self, command: ["ls": true], core: core, expected: binding)
            let terminal = try current.terminals().first { $0.address == target.address }
            if terminal?.paneID == destination.paneID, terminal?.spaceID == destination.spaceID,
               terminal?.tabID == destination.tabID, current.isActive(destination),
               status.space == destination.spaceID, status.tab == destination.tabID,
               status.focused_pane == destination.paneID, status.agent == destination.address {
                if await isForeground(binding.appProcessID) {
                    // shortcut: App 0.1.10 exposes selection, not rendered visibility; use its visibility API when available.
                    _ = try prove(appProcessID: binding.appProcessID, core: core, expected: binding)
                    return
                }
                failure = .notForeground
            }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        throw failure
    }

    private func connectCore(entryCoreID: String) throws -> HerdrCoreRPC {
        do {
            let core = try coreClient.connect()
            do {
                guard !entryCoreID.isEmpty, try core.hello().core.id == entryCoreID,
                      let pid = core.transport.peerProcessID, pid > 0 else { throw HerdrAppError.identityUnverified }
                return core
            } catch { core.close(); throw error }
        } catch let error as HerdrAppError { throw error }
        catch { throw HerdrAppError.coreUnavailable }
    }

    private func prove(appProcessID: Int32, core: HerdrCoreRPC, expected: HerdrAppProcessBinding?) throws -> HerdrAppProcessBinding {
        guard let corePID = core.transport.peerProcessID, corePID > 0, appProcessID > 0 else {
            throw HerdrAppError.identityUnverified
        }
        // LaunchServices can briefly fail to resolve a running App; a real mismatch still fails every attempt.
        var verified = try? nativeProof(appProcessID, corePID)
        for _ in 0..<2 where verified == nil {
            usleep(20_000)
            verified = try? nativeProof(appProcessID, corePID)
        }
        guard let proof = verified else { throw HerdrAppError.identityUnverified }
        guard proof.appProcessID == appProcessID, proof.coreProcessID == corePID,
              expected == nil || expected == proof else { throw HerdrAppError.identityUnverified }
        return proof
    }

    private func request<T: Decodable>(
        _ type: T.Type, command: [String: Any], core: HerdrCoreRPC, expected: HerdrAppProcessBinding? = nil
    ) throws -> (T, HerdrAppProcessBinding) {
        try Task.checkCancellation()
        guard let appHome else { throw HerdrAppError.invalidConfiguration }
        let stream: any HerdrCoreTransport
        do { stream = try transportFactory(URL(fileURLWithPath: appHome).appendingPathComponent("herdr-app.sock").path) }
        catch { throw HerdrAppError.unavailable }
        defer { stream.close() }
        guard let appPID = stream.peerProcessID else { throw HerdrAppError.identityUnverified }
        let binding = try prove(appProcessID: appPID, core: core, expected: expected)
        let data: Data
        do {
            try stream.write(JSONSerialization.data(withJSONObject: command))
            guard let line = try stream.readLine(timeout: 5) else { throw HerdrAppError.unavailable }
            data = line
        } catch { throw HerdrAppError.unavailable }
        // The App closes its one-reply socket; LOCAL_PEERPID may then be unavailable on the same owned descriptor.
        _ = try prove(appProcessID: appPID, core: core, expected: binding)
        do {
            let envelope = try JSONDecoder().decode(ResponseError.self, from: data)
            guard envelope.error == nil else { throw HerdrAppError.commandFailed }
            let response = try JSONDecoder().decode(type, from: data)
            if let acknowledgement = response as? Acknowledgement, !acknowledgement.ok { throw HerdrAppError.commandFailed }
            return (response, binding)
        } catch let error as HerdrAppError { throw error }
        catch { throw HerdrAppError.invalidResponse }
    }

    private func launchApp() async throws {
        try Task.checkCancellation()
        guard let appHome, let socketPath = coreClient.socketPath else { throw HerdrAppError.invalidConfiguration }
        var launchEnvironment = environment.filter { !$0.key.hasPrefix("HC_") && !$0.key.hasPrefix("HERDR_") }
        launchEnvironment["HC_SOCKET"] = socketPath
        launchEnvironment["HERDR_APP_HOME"] = appHome
        do { try await launch(launchEnvironment) }
        catch let error as HerdrAppError { throw error }
        catch { throw HerdrAppError.launchFailed }
    }

    private func waitForApp(core: HerdrCoreRPC) async throws -> (World, HerdrAppProcessBinding) {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try Task.checkCancellation()
            do { return try request(World.self, command: ["ls": true], core: core) }
            catch HerdrAppError.unavailable { }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw HerdrAppError.unavailable
    }

    static func home(environment: [String: String], homeDirectory: URL) throws -> String {
        let base: String
        if let explicit = environment["HERDR_APP_HOME"], !explicit.isEmpty { base = explicit }
        else if let config = environment["XDG_CONFIG_HOME"], !config.isEmpty {
            guard config.hasPrefix("/"), !config.contains("\0") else { throw HerdrAppError.invalidConfiguration }
            base = URL(fileURLWithPath: config).appendingPathComponent("herdr-app").path
        } else { base = homeDirectory.appendingPathComponent(".config/herdr-app").path }
        guard base.hasPrefix("/"), !base.contains("\0"),
              base.utf8.count + "/herdr-app.sock".utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw HerdrAppError.invalidConfiguration
        }
        return URL(fileURLWithPath: base).path
    }

    @MainActor
    private static func launchApplication(environment: [String: String]) async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "dev.herdr.app").isEmpty else {
            throw HerdrAppError.identityUnverified
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.herdr.app") else {
            throw HerdrAppError.launchFailed
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.environment = environment
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        guard application.bundleIdentifier == "dev.herdr.app" else { throw HerdrAppError.launchFailed }
    }

    private struct ResponseError: Decodable { let error: String? }
    private struct Acknowledgement: Decodable { let ok: Bool }
    private struct WindowStatus: Decodable {
        let space: String?
        let tab: String?
        let focused_pane: String?
        let agent: String?
    }

    private struct World: Decodable {
        struct Space: Decodable {
            let id: String
            let active: Bool
            let tabs: [Tab]
        }
        struct Tab: Decodable {
            let id: String
            let active: Bool
            let terminals: [Terminal]
        }
        struct Terminal: Decodable {
            let terminal: String
            let pane: String
            let status: String?
        }
        let spaces: [Space]

        func terminals() throws -> [HerdrAppTerminal] {
            var ids = Set<String>()
            var addresses = Set<String>()
            var terminals: [HerdrAppTerminal] = []
            func validID(_ id: String) -> Bool {
                !id.isEmpty && id.utf8.count <= 256 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            for space in spaces {
                guard validID(space.id), ids.insert(space.id).inserted else { throw HerdrAppError.invalidResponse }
                for tab in space.tabs {
                    guard validID(tab.id), ids.insert(tab.id).inserted else { throw HerdrAppError.invalidResponse }
                    for terminal in tab.terminals {
                        guard validID(terminal.pane), ids.insert(terminal.pane).inserted,
                              addresses.insert(terminal.terminal).inserted,
                              (try? HerdrCoreClient.addressParts(terminal.terminal)) != nil else { throw HerdrAppError.invalidResponse }
                        let status = terminal.status.map { AgentStatus(rawValue: $0) ?? .unknown }
                        terminals.append(.init(address: terminal.terminal, status: status, paneID: terminal.pane, spaceID: space.id, tabID: tab.id))
                    }
                }
            }
            return terminals
        }

        func isActive(_ terminal: HerdrAppTerminal) -> Bool {
            spaces.filter(\.active).count == 1
                && spaces.first { $0.id == terminal.spaceID && $0.active }?.tabs.filter(\.active).map(\.id) == [terminal.tabID]
        }
    }
}
