import Foundation
import Observation
import ServiceManagement

struct SourceRetryPolicy {
    static func delay(afterFailure count: Int) -> TimeInterval? {
        guard count >= 2 else { return nil }
        return min(15 * pow(2, Double(count - 2)), 60)
    }
}

enum AgentStatus: String, Sendable {
    case blocked
    case done
    case working
    case idle
    case unknown

}

struct AgentStatusCount: Equatable, Identifiable {
    var id: String { status.rawValue }
    let status: AgentStatus
    let count: Int

    static func summarize(_ agents: [AgentInfo]) -> [Self] {
        [AgentStatus.blocked, .done, .working, .idle, .unknown].compactMap { status in
            let count = agents.count { $0.status == status }
            return count == 0 ? nil : Self(status: status, count: count)
        }
    }
}

struct AgentInfo: Identifiable, Sendable {
    var id: String { paneID }
    let paneID: String
    let title: String
    let status: AgentStatus
    let workspace: String
    let cwd: String
    let updatedAt: Date
}

struct AgentGroup: Identifiable, Sendable {
    let id: String
    let name: String
    var agents: [AgentInfo]
}

@MainActor
final class LatestRequestRunner<Request> {
    private let operation: @MainActor (Request) async -> Void
    private var pending: Request?
    private(set) var isRunning = false

    var hasPendingRequest: Bool { pending != nil }

    init(operation: @escaping @MainActor (Request) async -> Void) {
        self.operation = operation
    }

    func submit(_ request: Request) {
        pending = request
        guard !isRunning else { return }
        isRunning = true
        Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            await operation(request)
        }
        isRunning = false
    }
}

private enum FocusRequest: Sendable {
    case agent(AgentInfo, SessionInfo, SourceDescriptor)
    case session(SessionInfo, SourceDescriptor)
}

struct SessionInfo: Identifiable, Sendable {
    var id: String { name }
    let name: String
    var groups: [AgentGroup]
    var online: Bool
    var updatedAt: Date?
    var error: String?

    var agents: [AgentInfo] { groups.flatMap(\.agents) }

    init(
        name: String,
        groups: [AgentGroup],
        online: Bool,
        updatedAt: Date? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.groups = groups
        self.online = online
        self.updatedAt = updatedAt
        self.error = error
    }

    init(
        name: String,
        agents: [AgentInfo],
        online: Bool,
        updatedAt: Date? = nil,
        error: String? = nil
    ) {
        var groups: [AgentGroup] = []
        for agent in agents {
            if let index = groups.firstIndex(where: { $0.name == agent.workspace }) {
                groups[index].agents.append(agent)
            } else {
                groups.append(AgentGroup(id: agent.workspace, name: agent.workspace, agents: [agent]))
            }
        }
        self.init(name: name, groups: groups, online: online, updatedAt: updatedAt, error: error)
    }
}

struct SourceInfo: Identifiable, Sendable {
    var id: String { descriptor.id }
    let descriptor: SourceDescriptor
    var sessions: [SessionInfo]
    var online: Bool
    var error: String?
    var branches: [String: String] = [:]
}

enum MenuAvailability: Equatable {
    case loading
    case online
    case offline
}

struct MenuStatus: Equatable {
    let counts: [AgentStatusCount]
    let availability: MenuAvailability

    static func summarize(_ sources: [SourceInfo]) -> Self {
        let onlineSources = sources.filter(\.online)
        guard !onlineSources.isEmpty else {
            return Self(
                counts: [],
                availability: sources.contains { $0.error == nil } ? .loading : .offline
            )
        }
        let agents = onlineSources.flatMap(\.sessions).filter(\.online).flatMap(\.agents)
        return Self(counts: AgentStatusCount.summarize(agents), availability: .online)
    }
}

@Observable
@MainActor
final class SessionStore {
    typealias SourceLoader = @Sendable (SourceDescriptor) throws -> [HerdrClient.LoadedSession]
    typealias BranchLoader = @Sendable (SourceDescriptor, [String]) async -> [String: String]

    private let client: HerdrClient
    private let loadSource: SourceLoader
    private let loadBranches: BranchLoader
    private let ghostty: GhosttyController
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let localMonitor: (any LocalSessionMonitoring)?
    private var pollTask: Task<Void, Never>?
    private var pollingStarted = false
    private var localMonitorActive = false
    private var pollGeneration = 0
    private var refreshRequested = false
    private var sourceFailureCounts: [String: Int] = [:]
    private var sourceRetryAfter: [String: Date] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private lazy var focusRunner = LatestRequestRunner<FocusRequest> { [weak self] request in
        await self?.performFocus(request)
    }

    private(set) var sources: [SourceInfo]
    private(set) var availableSSHAliases: [String]
    private(set) var selectedSSHAliases: [String]
    private(set) var focusError: String?
    private(set) var settingsError: String?
    private(set) var automationStatus = "Not checked"
    private var isRefreshing = false
    private var panelOpen = false
    private(set) var showingSettings = false

    var menuStatus: MenuStatus { MenuStatus.summarize(sources) }
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    convenience init() {
        self.init(client: HerdrClient(), localMonitor: HerdrLocalSessionMonitor())
    }

    init(
        client: HerdrClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        loadSource: SourceLoader? = nil,
        loadBranches: BranchLoader? = nil,
        localMonitor: (any LocalSessionMonitoring)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let aliases = SSHConfig.aliases()
        let persisted = UserDefaults.standard.stringArray(forKey: "selected-ssh-aliases") ?? []
        let selected = aliases.filter(persisted.contains)
        let ghostty = GhosttyController()
        self.client = client
        self.loadSource = loadSource ?? { try client.load($0) }
        self.loadBranches = loadBranches ?? { source, paths in
            await GitBranchResolver.shared.branches(source: source, paths: paths)
        }
        self.sleep = sleep
        self.now = now
        self.localMonitor = localMonitor
        self.ghostty = ghostty
        availableSSHAliases = aliases
        selectedSSHAliases = selected
        if selected != persisted { UserDefaults.standard.set(selected, forKey: "selected-ssh-aliases") }
        let descriptors = [SourceDescriptor.local] + selected.map(SourceDescriptor.remote)
        sources = descriptors.map { SourceInfo(descriptor: $0, sessions: [], online: false, error: nil) }
    }

    func start() {
        guard !pollingStarted else { return }
        pollingStarted = true
        if let localMonitor {
            Task { [weak self] in
                await localMonitor.start { [weak self] event in
                    await self?.handleLocalMonitor(event)
                }
            }
        }
        Task { await refresh() }
        scheduleNextPoll()
    }

    func stop() {
        pollingStarted = false
        refreshRequested = false
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        localMonitorActive = false
        if let localMonitor { Task { await localMonitor.stop() } }
    }

    func setPanelOpen(_ open: Bool) {
        guard panelOpen != open else { return }
        panelOpen = open
        guard pollingStarted else { return }
        scheduleNextPoll()
        if open { Task { await refresh() } }
    }

    func setShowingSettings(_ showing: Bool) {
        showingSettings = showing
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            onChange?()
            let shouldRefreshAgain = refreshRequested && pollingStarted
            refreshRequested = false
            if shouldRefreshAgain {
                Task { await refresh() }
            }
        }

        let loadSource = self.loadSource
        let loadBranches = self.loadBranches
        let currentTime = now()
        let descriptors = sources.map(\.descriptor).filter { descriptor in
            if localMonitorActive, descriptor == .local { return false }
            guard descriptor.sshAlias != nil, let retryAfter = sourceRetryAfter[descriptor.id] else {
                return true
            }
            return retryAfter <= currentTime
        }
        let previousSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var completed: [String: SourceLoad] = [:]
        await withTaskGroup(of: SourceLoad.self) { group in
            for descriptor in descriptors {
                let previousSessions = previousSources[descriptor.id]?.sessions ?? []
                group.addTask {
                    do {
                        let loaded = try loadSource(descriptor)
                        let sessions = Self.sessions(from: loaded, previous: previousSessions)
                        let paths = Self.branchPaths(from: sessions)
                        let branches = await loadBranches(descriptor, paths)
                        return SourceLoad(
                            descriptor: descriptor,
                            sessions: sessions,
                            branches: branches,
                            error: nil
                        )
                    } catch {
                        return SourceLoad(
                            descriptor: descriptor,
                            sessions: nil,
                            branches: [:],
                            error: error.localizedDescription
                        )
                    }
                }
            }

            for await load in group {
                completed[load.descriptor.id] = load
            }
        }

        var nextSources = sources
        for index in nextSources.indices {
            let current = nextSources[index]
            guard let load = completed[current.id] else { continue }
            if load.descriptor == .local, localMonitorActive { continue }
            var updated = current
            if let loaded = load.sessions {
                sourceFailureCounts[load.descriptor.id] = 0
                sourceRetryAfter.removeValue(forKey: load.descriptor.id)
                updated.online = true
                updated.error = nil
                updated.sessions = loaded
                updated.branches = load.branches
            } else {
                let failureCount = (sourceFailureCounts[load.descriptor.id] ?? 0) + 1
                sourceFailureCounts[load.descriptor.id] = failureCount
                if load.descriptor.sshAlias != nil,
                   let delay = SourceRetryPolicy.delay(afterFailure: failureCount)
                {
                    sourceRetryAfter[load.descriptor.id] = now().addingTimeInterval(delay)
                }
                updated.online = false
                let retryingInitialLoad = pollingStarted && updated.sessions.isEmpty && failureCount == 1
                updated.error = retryingInitialLoad ? nil : load.error
                updated.sessions = updated.sessions.map {
                    var stale = $0
                    stale.online = false
                    return stale
                }
                if retryingInitialLoad { refreshRequested = true }
            }
            nextSources[index] = updated
        }
        sources = nextSources
    }

    private func handleLocalMonitor(_ event: LocalSessionMonitorEvent) async {
        guard pollingStarted else { return }
        switch event {
        case let .sessions(loaded):
            localMonitorActive = true
            guard let index = sources.firstIndex(where: { $0.descriptor == .local }) else { return }
            let sessions = Self.sessions(from: loaded, previous: sources[index].sessions)
            let branches = await loadBranches(.local, Self.branchPaths(from: sessions))
            guard pollingStarted, localMonitorActive,
                  let currentIndex = sources.firstIndex(where: { $0.descriptor == .local })
            else { return }
            sourceFailureCounts[SourceDescriptor.local.id] = 0
            var local = sources[currentIndex]
            local.sessions = sessions
            local.branches = branches
            local.online = true
            local.error = nil
            sources[currentIndex] = local
            onChange?()
        case .unavailable:
            let usedStream = localMonitorActive
            localMonitorActive = false
            if usedStream { await refresh() }
        }
    }

    func focus(_ agent: AgentInfo, in session: SessionInfo, source: SourceDescriptor = .local) {
        guard session.online else { return }
        focusRunner.submit(.agent(agent, session, source))
    }

    func focusSession(_ session: SessionInfo, source: SourceDescriptor = .local) {
        guard session.online else { return }
        focusRunner.submit(.session(session, source))
    }

    private func performFocus(_ request: FocusRequest) async {
        focusError = nil
        defer { onChange?() }

        do {
            switch request {
            case let .agent(agent, session, source):
                try await ghostty.activateClient(
                    source: source,
                    session: session.name,
                    command: try client.attachCommand(source: source, session: session.name)
                )
                guard !focusRunner.hasPendingRequest else { return }
                try await runHerdrFocus(source: source, session: session.name, paneID: agent.paneID)
            case let .session(session, source):
                try await ghostty.activateClient(
                    source: source,
                    session: session.name,
                    command: try client.attachCommand(source: source, session: session.name)
                )
            }
        } catch {
            if !focusRunner.hasPendingRequest { focusError = error.localizedDescription }
        }
    }

    func setRemoteAlias(_ alias: String, enabled: Bool) {
        if enabled, availableSSHAliases.contains(alias), !selectedSSHAliases.contains(alias) {
            selectedSSHAliases.append(alias)
        }
        if !enabled { selectedSSHAliases.removeAll { $0 == alias } }
        selectedSSHAliases.sort { (availableSSHAliases.firstIndex(of: $0) ?? .max) < (availableSSHAliases.firstIndex(of: $1) ?? .max) }
        UserDefaults.standard.set(selectedSSHAliases, forKey: "selected-ssh-aliases")
        let old = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let descriptors = [SourceDescriptor.local] + selectedSSHAliases.map(SourceDescriptor.remote)
        let retainedIDs = Set(descriptors.map(\.id))
        sourceFailureCounts = sourceFailureCounts.filter { retainedIDs.contains($0.key) }
        sourceRetryAfter = sourceRetryAfter.filter { retainedIDs.contains($0.key) }
        sources = descriptors.map { old[$0.id] ?? SourceInfo(descriptor: $0, sessions: [], online: false, error: nil) }
        onChange?()
        Task { await refresh() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            settingsError = switch SMAppService.mainApp.status {
            case .requiresApproval:
                "Launch at Login requires approval in System Settings."
            case .notFound:
                "Herdling must run from an app bundle before Launch at Login can be enabled."
            default:
                nil
            }
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func refreshPermissionStatus() async {
        automationStatus = await ghostty.automationPermissionStatus()
    }

    var pollInterval: Duration { .seconds(panelOpen ? 2 : 15) }

    private func scheduleNextPoll() {
        pollTask?.cancel()
        pollGeneration += 1
        let generation = pollGeneration
        let interval = pollInterval
        let sleep = self.sleep
        pollTask = Task { [weak self] in
            do { try await sleep(interval) }
            catch { return }
            await self?.pollDidFire(generation: generation)
        }
    }

    private func pollDidFire(generation: Int) async {
        guard pollingStarted, generation == pollGeneration else { return }
        pollTask = nil
        await refresh()
        if pollingStarted, generation == pollGeneration, pollTask == nil { scheduleNextPoll() }
    }

    private func runHerdrFocus(source: SourceDescriptor, session: String, paneID: String) async throws {
        let client = self.client
        try await Task.detached { try client.focus(source: source, session: session, paneID: paneID) }.value
    }

    nonisolated static func branchPaths(from sessions: [SessionInfo]) -> [String] {
        var seen: Set<String> = []
        return sessions.flatMap(\.agents).map(\.cwd).filter { seen.insert($0).inserted }
    }

    private nonisolated static func sessions(
        from loaded: [HerdrClient.LoadedSession],
        previous: [SessionInfo]
    ) -> [SessionInfo] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })
        return loaded.map { item in
            if let groups = item.groups {
                let timestamp = groups.flatMap(\.agents).map(\.updatedAt).max() ?? .now
                return SessionInfo(
                    name: item.name,
                    groups: groups,
                    online: true,
                    updatedAt: timestamp,
                    error: nil
                )
            }
            var stale = old[item.name] ?? SessionInfo(name: item.name, agents: [], online: false)
            stale.online = false
            stale.error = item.error
            return stale
        }
    }
}

private struct SourceLoad: Sendable {
    let descriptor: SourceDescriptor
    let sessions: [SessionInfo]?
    let branches: [String: String]
    let error: String?
}
