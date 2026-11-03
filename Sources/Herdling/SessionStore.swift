import Foundation
import Observation
import ServiceManagement

private enum DefaultsKey {
    static let selectedSSHAliases = "selected-ssh-aliases"
    static let terminalApplication = "terminal-application"
    static let ghosttyOpenBehavior = "ghostty-open-behavior"
    static let expandedSource = "expanded.source"
}

enum AgentStatus: String, Sendable {
    case blocked
    case error
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
        summarize(statuses: agents.map(\.status))
    }

    static func summarize(statuses: [AgentStatus]) -> [Self] {
        [AgentStatus.blocked, .error, .done, .working, .idle, .unknown].compactMap { status in
            let count = statuses.count { $0 == status }
            return count == 0 ? nil : Self(status: status, count: count)
        }
    }
}

struct AgentInfo: Identifiable, Sendable {
    var id: String { paneID }
    let paneID: String
    let tabID: String?
    let title: String
    let status: AgentStatus
    let workspace: String
    let cwd: String
    let revision: UInt64?
    var updatedAt: Date

    init(
        paneID: String,
        tabID: String? = nil,
        title: String,
        status: AgentStatus,
        workspace: String,
        cwd: String,
        revision: UInt64? = nil,
        updatedAt: Date
    ) {
        self.paneID = paneID
        self.tabID = tabID
        self.title = title
        self.status = status
        self.workspace = workspace
        self.cwd = cwd
        self.revision = revision
        self.updatedAt = updatedAt
    }
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

private struct FocusRequest: Sendable {
    let destination: NavigationDestination
    let token: UUID
    let terminalApplication: TerminalApplication
    let ghosttyOpenBehavior: GhosttyOpenBehavior
}

private enum NavigationValidationError: LocalizedError {
    case missing
    case offline

    var errorDescription: String? {
        switch self {
        case .missing: "This item is no longer available. Update the list, then retry."
        case .offline: "This source or session is offline. Reconnect, then retry."
        }
    }
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
    var retryAt: Date? = nil
    var branches: [String: String] = [:]
    var hasLegacy = true
    var core: CoreSourceInfo?

    var isAvailable: Bool { (hasLegacy && online) || core?.online == true }
    var hasUnavailableRuntime: Bool {
        (hasLegacy && (!online || sessions.contains { !$0.online })) || core?.online == false
    }
    var showsLegacy: Bool { hasLegacy && (core == nil || !sessions.isEmpty || error != nil || descriptor.sshAlias != nil) }
    var reportedStatuses: [AgentStatus] {
        let legacy = hasLegacy && online ? sessions.filter(\.online).flatMap(\.agents).map(\.status) : []
        let reported = core?.online == true ? core?.terminals.filter(\.online).compactMap(\.status) ?? [] : []
        return legacy + reported
    }
}

struct CoreTerminalInfo: Identifiable, Sendable {
    var id: CoreTerminalID { target.id }
    let target: CoreTerminalTarget
    let title: String
    let status: AgentStatus?
    let cwd: String
    let updatedAt: Date
    var online: Bool
    var workingSubAgents = 0

    /// One row for an agent and the sub-agents it started, as Herdr T3 reads them: a stuck sub-agent needs the
    /// person; the parent's unread reply comes next; a parent waiting on working sub-agents is still at work; a
    /// sub-agent's own done is news for its parent, not for the person. Without an App status it is no agent row.
    static func treeStatus(own: AgentStatus?, subAgents: [AgentStatus]) -> AgentStatus? {
        guard let own else { return nil }
        if own == .blocked || own == .error { return own }
        let kids = subAgents.map { $0 == .error ? .blocked : $0 == .done ? .idle : $0 }
        if kids.contains(.blocked) { return .blocked }
        return own != .done && kids.contains(.working) ? .working : own
    }
}

struct CoreSourceInfo: Sendable {
    let coreID: String?
    var terminals: [CoreTerminalInfo]
    var online: Bool
    var error: String?
    var retryAt: Date?
}

struct AgentFocusID: Hashable, Sendable {
    let sourceID: String
    let sessionName: String
    let paneID: String
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
        let onlineSources = sources.filter(\.isAvailable)
        guard !onlineSources.isEmpty else {
            return Self(
                counts: [],
                availability: sources.allSatisfy { !$0.hasLegacy && $0.core == nil } ? .online
                    : sources.contains { $0.hasLegacy && !$0.online && $0.error == nil } ? .loading : .offline
            )
        }
        let statuses = onlineSources.flatMap(\.reportedStatuses).filter { $0 != .unknown }
        return Self(counts: AgentStatusCount.summarize(statuses: statuses), availability: .online)
    }
}

@Observable
@MainActor
final class SessionStore {
    struct WorkspaceFocusID: Equatable {
        let sourceID: String
        let sessionName: String
        let workspaceID: String
    }

    typealias SourceLoader = @Sendable (SourceDescriptor) async throws -> [HerdrClient.LoadedSession]
    typealias BranchLoader = @Sendable (SourceDescriptor, [String]) async -> [String: String]
    typealias RemoteMonitorFactory = @Sendable (SourceDescriptor) -> any SessionMonitoring
    typealias ExistingClientFocus = @Sendable (SourceDescriptor, String, TerminalApplication) async throws -> Bool
    typealias ClientActivation = @Sendable (SourceDescriptor, String, String, TerminalApplication, GhosttyOpenBehavior) async throws -> Void
    typealias TerminalStatusLoader = @Sendable (TerminalApplication) async -> String
    typealias CoreAppFocus = @Sendable (CoreTerminalTarget) async throws -> Void
    typealias CoreAppSnapshotLoader = @Sendable (String) async throws -> HerdrAppSnapshot
    typealias CoreAppChanges = @MainActor () -> AsyncThrowingStream<Void, Error>

    private let client: HerdrClient
    private let loadSource: SourceLoader
    private let loadBranches: BranchLoader
    private let focusExistingClient: ExistingClientFocus
    private let activateClient: ClientActivation
    private let loadTerminalStatus: TerminalStatusLoader
    private let coreMonitor: (any HerdrCoreMonitoring)?
    let legacyEnabled: Bool
    private let focusCoreApp: CoreAppFocus
    private let loadCoreAppSnapshot: CoreAppSnapshotLoader
    private let coreAppChanges: CoreAppChanges
    private var latestCoreSnapshot: HerdrCoreSnapshot?
    private var coreAppSnapshot: HerdrAppSnapshot?
    private var coreAppError: String?
    private var coreAppTask: Task<Void, Never>?
    private var coreAppReadTask: Task<HerdrAppSnapshot, Error>?
    private var coreAppRequest = UUID()
    private var coreMonitorTask: Task<Void, Never>?
    private var coreMonitorGeneration: UUID?
    private let loadLoginItemStatus: () -> SMAppService.Status
    private let updateLoginItem: (Bool) throws -> Void
    private var terminalStatusRequest: UUID?
    private let defaults: UserDefaults
    private let sleep: @Sendable (Duration) async throws -> Void
    private let localMonitor: (any SessionMonitoring)?
    private let remoteMonitorFactory: RemoteMonitorFactory?
    private var remoteMonitors: [String: any SessionMonitoring] = [:]
    private var monitorGenerations: [String: UUID] = [:]
    private var monitorStartTasks: [String: Task<Void, Never>] = [:]
    private var branchLoadGenerations: [String: UUID] = [:]
    private var pollFallbackSourceIDs: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var pollingStarted = false
    private var pollGeneration = 0
    private var refreshRequested = false
    private var sourceFailureCounts: [String: Int] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onClientActivated: (() -> Void)?
    @ObservationIgnored private lazy var focusRunner = LatestRequestRunner<FocusRequest> { [weak self] request in
        await self?.performFocus(request)
    }

    private(set) var sources: [SourceInfo] {
        didSet { pruneSuccessfulJumps() }
    }
    private(set) var availableSSHAliases: [String]
    private(set) var selectedSSHAliases: [String]
    private(set) var focusError: String?
    private(set) var navigationAttempt: NavigationAttempt?
    private(set) var successfulJumps: [NavigationDestination] = []
    @ObservationIgnored private var navigationToken = UUID()
    @ObservationIgnored private var acceptsNavigation = true

    var pendingFocusAgentID: AgentFocusID? {
        guard navigationAttempt?.phase == .pending,
              case let .agent(sourceID, sessionName, paneID) = navigationAttempt?.destination
        else { return nil }
        return AgentFocusID(
            sourceID: sourceID,
            sessionName: sessionName,
            paneID: paneID
        )
    }

    var pendingFocusWorkspaceID: WorkspaceFocusID? {
        guard navigationAttempt?.phase == .pending,
              case let .workspace(sourceID, sessionName, workspaceID) = navigationAttempt?.destination
        else { return nil }
        return WorkspaceFocusID(
            sourceID: sourceID,
            sessionName: sessionName,
            workspaceID: workspaceID
        )
    }

    /// Whether this workspace is the one a focus is currently opening, so whichever row stands for
    /// it — a worktree's own, or a space's when the space has only `Main` — can say so.
    func isFocusing(_ group: AgentGroup, in session: SessionInfo, source: SourceDescriptor) -> Bool {
        pendingFocusWorkspaceID == WorkspaceFocusID(
            sourceID: source.id,
            sessionName: session.name,
            workspaceID: group.id
        )
    }
    private var loginItemStatus = SMAppService.Status.notRegistered
    private var loginItemError: String?
    private(set) var terminalStatus = "Not checked"
    private(set) var terminalApplication: TerminalApplication
    private(set) var ghosttyOpenBehavior: GhosttyOpenBehavior
    private var isRefreshing = false
    private(set) var panelOpen = false

    /// The expanded directory in Sources. Persisted through the store's own `defaults`, not through
    /// `@AppStorage`: a view that keeps its own copy writes to the standard domain even when the
    /// store was handed a different one, which is both untestable and invisible.
    var expandedSourceID: String {
        get { defaults.string(forKey: DefaultsKey.expandedSource) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.expandedSource) }
    }

    var menuStatus: MenuStatus { MenuStatus.summarize(sources) }
    var launchAtLoginEnabled: Bool { loginItemStatus == .enabled }
    var settingsError: String? {
        if let loginItemError { return loginItemError }
        return switch loginItemStatus {
        case .requiresApproval:
            "Launch at Login requires approval in System Settings."
        case .notFound:
            "Herdling must run from an app bundle before Launch at Login can be enabled."
        default:
            nil
        }
    }

    convenience init() {
        let client = HerdrClient()
        let coreClient = HerdrCoreClient()
        self.init(
            client: client,
            localMonitor: HerdrLocalSessionMonitor(),
            remoteMonitorFactory: { HerdrRemoteSessionMonitor(source: $0) },
            coreClient: coreClient,
            coreMonitor: HerdrCoreMonitor(client: coreClient),
            legacyEnabled: client.isInstalled
        )
    }

    init(
        client: HerdrClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        loadTerminalStatus: TerminalStatusLoader? = nil,
        loadLoginItemStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        updateLoginItem: @escaping (Bool) throws -> Void = { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        },
        loadSource: SourceLoader? = nil,
        loadBranches: BranchLoader? = nil,
        localMonitor: (any SessionMonitoring)? = nil,
        remoteMonitorFactory: RemoteMonitorFactory? = nil,
        focusExistingClient: ExistingClientFocus? = nil,
        sourceDescriptors: [SourceDescriptor]? = nil,
        defaults: UserDefaults = .standard,
        activateClient: ClientActivation? = nil,
        coreClient: HerdrCoreClient = HerdrCoreClient(),
        coreMonitor: (any HerdrCoreMonitoring)? = nil,
        coreAppChanges: CoreAppChanges? = nil,
        legacyEnabled: Bool = true,
        focusCoreApp: CoreAppFocus? = nil,
        loadCoreAppSnapshot: CoreAppSnapshotLoader? = nil
    ) {
        let persisted = defaults.stringArray(forKey: DefaultsKey.selectedSSHAliases) ?? []
        let aliases = sourceDescriptors?.compactMap(\.sshAlias) ?? SSHConfig.aliases()
        let selected = sourceDescriptors?.compactMap(\.sshAlias) ?? aliases.filter(persisted.contains)
        let kero = KeroController()
        let ghostty = GhosttyController()
        let herdrApp = HerdrAppController(coreClient: coreClient)
        self.client = client
        self.coreMonitor = coreMonitor
        self.legacyEnabled = legacyEnabled
        self.focusCoreApp = focusCoreApp ?? { try await herdrApp.focus(target: $0) }
        self.loadCoreAppSnapshot = loadCoreAppSnapshot ?? { try await herdrApp.snapshot(entryCoreID: $0) }
        self.coreAppChanges = coreAppChanges ?? { HerdrAppStateObserver.changes() }
        self.loadSource = loadSource ?? { try await client.load($0) }
        self.loadBranches = loadBranches ?? { source, paths in
            await GitBranchResolver.shared.branches(source: source, paths: paths)
        }
        self.sleep = sleep
        self.localMonitor = localMonitor
        self.remoteMonitorFactory = remoteMonitorFactory
        self.focusExistingClient = focusExistingClient ?? { source, session, application in
            switch application {
            case .ghostty: try await ghostty.focusExistingClient(source: source, session: session)
            case .kero: try await kero.focusExistingClient(source: source, session: session)
            }
        }
        self.activateClient = activateClient ?? { source, session, command, application, behavior in
            switch application {
            case .ghostty:
                try await ghostty.activateClient(source: source, session: session, command: command, openBehavior: behavior)
            case .kero:
                try await kero.activateClient(source: source, session: session, command: command)
            }
        }
        self.loadTerminalStatus = loadTerminalStatus ?? { application in
            switch application {
            case .ghostty: await ghostty.automationPermissionStatus()
            case .kero: await kero.connectionStatus()
            }
        }
        self.loadLoginItemStatus = loadLoginItemStatus
        self.updateLoginItem = updateLoginItem
        self.defaults = defaults
        availableSSHAliases = aliases
        selectedSSHAliases = selected
        terminalApplication = TerminalApplication(rawValue: defaults.string(forKey: DefaultsKey.terminalApplication) ?? "") ?? .ghostty
        ghosttyOpenBehavior = GhosttyOpenBehavior(rawValue: defaults.string(forKey: DefaultsKey.ghosttyOpenBehavior) ?? "") ?? .tab
        if sourceDescriptors == nil, selected != persisted {
            defaults.set(selected, forKey: DefaultsKey.selectedSSHAliases)
        }
        let descriptors = sourceDescriptors ?? ([SourceDescriptor.local] + selected.map(SourceDescriptor.remote))
        sources = descriptors.map {
            SourceInfo(descriptor: $0, sessions: [], online: false, error: nil, hasLegacy: legacyEnabled)
        }
    }

    func start() {
        guard !pollingStarted else { return }
        acceptsNavigation = true
        pollingStarted = true
        if let coreMonitor {
            let generation = UUID()
            coreMonitorGeneration = generation
            coreMonitorTask = Task { [weak self] in
                await coreMonitor.start { [weak self] event in
                    await self?.handleCoreMonitor(event, generation: generation)
                }
                guard let self, self.pollingStarted, self.coreMonitorGeneration == generation else {
                    await coreMonitor.stop()
                    return
                }
            }
            let changes = coreAppChanges()
            coreAppTask = Task { [weak self] in
                do {
                    for try await _ in changes {
                        guard let self, self.pollingStarted, self.coreMonitorGeneration == generation else { return }
                        // An invalidation must not reuse a snapshot started before that change.
                        let request = self.coreAppRequest
                        _ = await self.coreAppReadTask?.result
                        guard !Task.isCancelled, self.coreMonitorGeneration == generation else { return }
                        _ = await self.refreshCoreAppState(forceRefresh: self.coreAppRequest == request)
                    }
                } catch {
                    guard let self, self.pollingStarted, self.coreMonitorGeneration == generation else { return }
                    self.coreAppReadTask?.cancel()
                    self.coreAppReadTask = nil
                    self.coreAppRequest = UUID()
                    self.coreAppSnapshot = nil
                    self.coreAppError = "Herdr App state notifications are unavailable. Reopen Herdling to reconnect."
                    if let snapshot = self.latestCoreSnapshot { self.applyCoreSnapshot(snapshot) }
                    self.onChange?()
                }
            }
        }
        if let localMonitor, sources.contains(where: { $0.id == SourceDescriptor.local.id && $0.hasLegacy }) {
            let generation = UUID()
            monitorGenerations[SourceDescriptor.local.id] = generation
            startMonitor(localMonitor, source: .local, generation: generation)
        }
        for descriptor in sources.filter(\.hasLegacy).map(\.descriptor) where descriptor.sshAlias != nil {
            startRemoteMonitor(for: descriptor)
        }
        Task { await refresh() }
        scheduleNextPoll()
    }

    func stop() {
        let plan = prepareToStop()
        Task { await finishStopping(plan) }
    }

    func stopAndWait() async {
        await finishStopping(prepareToStop())
    }

    private func prepareToStop() -> (
        local: (any SessionMonitoring)?,
        remotes: [any SessionMonitoring],
        starts: [Task<Void, Never>],
        core: (any HerdrCoreMonitoring)?,
        coreStart: Task<Void, Never>?,
        coreApp: Task<Void, Never>?,
        coreAppRead: Task<HerdrAppSnapshot, Error>?
    ) {
        acceptsNavigation = false
        navigationToken = UUID()
        navigationAttempt = nil
        focusError = nil
        pollingStarted = false
        refreshRequested = false
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        monitorGenerations.removeAll()
        pollFallbackSourceIDs.removeAll()
        let monitors = Array(remoteMonitors.values)
        remoteMonitors.removeAll()
        let starts = Array(monitorStartTasks.values)
        starts.forEach { $0.cancel() }
        monitorStartTasks.removeAll()
        coreMonitorGeneration = nil
        let coreStart = coreMonitorTask
        coreStart?.cancel()
        coreMonitorTask = nil
        let coreApp = coreAppTask
        coreApp?.cancel()
        coreAppTask = nil
        let coreAppRead = coreAppReadTask
        coreAppRead?.cancel()
        coreAppReadTask = nil
        coreAppRequest = UUID()
        latestCoreSnapshot = nil
        coreAppSnapshot = nil
        return (localMonitor, monitors, starts, coreMonitor, coreStart, coreApp, coreAppRead)
    }

    private func finishStopping(_ plan: (
        local: (any SessionMonitoring)?,
        remotes: [any SessionMonitoring],
        starts: [Task<Void, Never>],
        core: (any HerdrCoreMonitoring)?,
        coreStart: Task<Void, Never>?,
        coreApp: Task<Void, Never>?,
        coreAppRead: Task<HerdrAppSnapshot, Error>?
    )) async {
        let monitors = [plan.local].compactMap { $0 } + plan.remotes
        // Stop once up front, then once more after the starts settle: a monitor whose start() was
        // already in flight re-arms itself when it finishes, so the trailing stop is the one that
        // guarantees it stays down. StopCount >= 2 is asserted by the race test.
        let stops = monitors.map { monitor in Task { await monitor.stop() } }
        let coreStop = Task { await plan.core?.stop() }
        for start in plan.starts { await start.value }
        for stop in stops { await stop.value }
        for monitor in monitors { await monitor.stop() }
        await plan.coreStart?.value
        await coreStop.value
        await plan.core?.stop()
        await plan.coreApp?.value
        _ = await plan.coreAppRead?.result
    }

    func setPanelOpen(_ open: Bool) {
        guard panelOpen != open else { return }
        panelOpen = open
        guard pollingStarted else { return }
        scheduleNextPoll(reset: true)
        if open {
            for source in sources where source.online && monitorOwnsSource(source.id) {
                guard let generation = monitorGenerations[source.id] else { continue }
                refreshBranches(for: source.descriptor, sessions: source.sessions, generation: generation)
            }
            Task { await refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        var didPublish = false
        defer {
            isRefreshing = false
            if didPublish { onChange?() }
            let shouldRefreshAgain = refreshRequested && pollingStarted
            refreshRequested = false
            if shouldRefreshAgain {
                Task { await refresh() }
            }
        }

        let loadSource = self.loadSource
        let loadBranches = self.loadBranches
        let descriptors = sources.filter(\.hasLegacy).map(\.descriptor).filter { !monitorOwnsSource($0.id) }
        guard !descriptors.isEmpty else { return }
        let previousSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var completed: [String: SourceLoad] = [:]
        await withTaskGroup(of: SourceLoad.self) { group in
            for descriptor in descriptors {
                let previousSessions = previousSources[descriptor.id]?.sessions ?? []
                group.addTask {
                    do {
                        let loaded = try await loadSource(descriptor)
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
            guard current.hasLegacy else { continue }
            guard let load = completed[current.id] else { continue }
            guard !monitorOwnsSource(load.descriptor.id) else { continue }
            var updated = current
            if let loaded = load.sessions {
                sourceFailureCounts[load.descriptor.id] = 0
                updated.online = true
                updated.error = nil
                updated.retryAt = nil
                updated.sessions = loaded
                updated.branches = load.branches
            } else {
                let failureCount = (sourceFailureCounts[load.descriptor.id] ?? 0) + 1
                sourceFailureCounts[load.descriptor.id] = failureCount
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
        didPublish = !completed.isEmpty
    }

    private func handleMonitor(
        _ event: SessionMonitorEvent,
        source descriptor: SourceDescriptor,
        generation: UUID
    ) async {
        guard pollingStarted, monitorGenerations[descriptor.id] == generation else { return }
        switch event {
        case let .sessions(loaded):
            let leftFallback = pollFallbackSourceIDs.remove(descriptor.id) != nil
            guard let index = sources.firstIndex(where: { $0.descriptor == descriptor }) else { return }
            let sessions = Self.sessions(from: loaded, previous: sources[index].sessions)
            let branchPaths = Self.branchPaths(from: sessions)
            let branchPathSet = Set(branchPaths)
            let previousBranchPaths = Set(Self.branchPaths(from: sources[index].sessions))
            if branchPathSet != previousBranchPaths {
                branchLoadGenerations[descriptor.id] = UUID()
            }
            sourceFailureCounts[descriptor.id] = 0
            var updated = sources[index]
            updated.sessions = sessions
            updated.branches = updated.branches.filter { branchPathSet.contains($0.key) }
            updated.online = true
            updated.error = nil
            updated.retryAt = nil
            sources[index] = updated
            if leftFallback { scheduleNextPoll() }
            onChange?()
            guard !branchPathSet.isSubset(of: previousBranchPaths) else { return }
            refreshBranches(for: descriptor, sessions: sessions, generation: generation)
        case let .unavailable(reason, retryAt):
            if descriptor == .local {
                let enteredFallback = pollFallbackSourceIDs.insert(descriptor.id).inserted
                if enteredFallback { scheduleNextPoll() }
                if enteredFallback { await refresh() }
            } else {
                markRemoteMonitorUnavailable(descriptor, reason: reason, retryAt: retryAt)
            }
        }
    }

    private func handleCoreMonitor(_ event: HerdrCoreMonitorEvent, generation: UUID) async {
        guard pollingStarted, coreMonitorGeneration == generation else { return }
        switch event {
        case let .snapshot(snapshot):
            let changed = latestCoreSnapshot != snapshot
            let needsAppSnapshot = latestCoreSnapshot?.entryCoreID != snapshot.entryCoreID
            if needsAppSnapshot {
                coreAppReadTask?.cancel()
                coreAppReadTask = nil
                coreAppSnapshot = nil
                coreAppRequest = UUID()
            }
            latestCoreSnapshot = snapshot
            applyCoreSnapshot(snapshot)
            if changed { _ = await refreshCoreAppState() }
        case let .unavailable(reason, retryAt):
            if !sources.contains(where: { $0.core != nil }),
               let index = sources.firstIndex(where: { $0.descriptor.isLocal })
            {
                sources[index].core = CoreSourceInfo(coreID: nil, terminals: [], online: false,
                                                    error: nil, retryAt: retryAt)
            }
            markCoreUnavailable(reason: reason ?? "Core connection unavailable.", retryAt: retryAt)
        case .absent:
            // An unused runtime is not an offline source. A previously observed one remains stale.
            markCoreUnavailable(reason: "Core is not running.", retryAt: nil)
        }
        onChange?()
    }

    private func markCoreUnavailable(reason: String, retryAt: Date?) {
        latestCoreSnapshot = nil
        coreAppSnapshot = nil
        coreAppReadTask?.cancel()
        coreAppReadTask = nil
        coreAppRequest = UUID()
        sources = sources.map { source in
            var source = source
            if var core = source.core {
                core.online = false
                core.error = reason
                core.retryAt = retryAt
                core.terminals = core.terminals.map { terminal in
                    var terminal = terminal
                    terminal.online = false
                    return terminal
                }
                source.core = core
            }
            return source
        }
    }

    @discardableResult
    func refreshCoreAppState(forceRefresh: Bool = false) async -> Bool {
        guard pollingStarted, let snapshot = latestCoreSnapshot else { return false }
        let generation = coreMonitorGeneration
        let read: Task<HerdrAppSnapshot, Error>
        if !forceRefresh, let pending = coreAppReadTask {
            read = pending
        } else {
            coreAppReadTask?.cancel()
            let load = loadCoreAppSnapshot
            read = Task { try await load(snapshot.entryCoreID) }
            coreAppReadTask = read
            coreAppRequest = UUID()
        }
        let request = coreAppRequest
        let observed: HerdrAppSnapshot?
        do {
            let result = try await read.value
            observed = result.entryCoreID == snapshot.entryCoreID ? result : nil
        } catch {
            observed = nil
        }
        guard pollingStarted, coreMonitorGeneration == generation,
              let current = latestCoreSnapshot, current.entryCoreID == snapshot.entryCoreID else { return false }
        if coreAppRequest == request {
            coreAppReadTask = nil
            coreAppSnapshot = observed
            coreAppError = observed == nil ? "Herdr App status is unavailable. Open Herdr App to refresh Core activity." : nil
            applyCoreSnapshot(current)
            onChange?()
        }
        return observed != nil
    }

    private func applyCoreSnapshot(_ snapshot: HerdrCoreSnapshot) {
        let previous = sources.compactMap(\.core).reduce(into: [String: CoreSourceInfo]()) {
            if let id = $1.coreID { $0[id] = $1 }
        }
        var next = sources.map { source in
            var source = source
            source.core = nil
            return source
        }
        var machines: [String: HerdrCoreMachine] = [:]
        for machine in snapshot.machines where !machine.id.isEmpty {
            if machines[machine.id] == nil || machine.online { machines[machine.id] = machine }
        }
        var coreIDs = [snapshot.entryCoreID]
        for machine in snapshot.machines where !coreIDs.contains(machine.id) && !machine.id.isEmpty {
            coreIDs.append(machine.id)
        }
        var seen: Set<CoreTerminalID> = []
        let terminals = snapshot.terminals.filter { seen.insert($0.target.id).inserted }
        let appStates = coreAppSnapshot?.entryCoreID == snapshot.entryCoreID
            ? coreAppSnapshot?.terminals.reduce(into: [String: AgentStatus]()) { states, terminal in
                states[terminal.address] = terminal.status
            } ?? [:] : [:]
        // A sub-agent without a pane has no App status; its Core report is all there is.
        let children = Dictionary(grouping: terminals.filter { $0.parent != nil }, by: { $0.parent! })
        func subAgentStatuses(of address: String) -> [AgentStatus] {
            var result: [AgentStatus] = [], pending = [address], visited: Set<String> = [address]
            while let next = pending.popLast() {
                for child in children[next] ?? [] where visited.insert(child.target.address).inserted {
                    pending.append(child.target.address)
                    if let status = appStates[child.target.address] ?? child.rawStatus.flatMap(AgentStatus.init(rawValue:)) {
                        result.append(status)
                    }
                }
            }
            return result
        }
        for coreID in coreIDs {
            let machine = coreID == snapshot.entryCoreID ? nil : machines[coreID]
            let online = machine?.online ?? (coreID == snapshot.entryCoreID)
            let records = terminals.filter { $0.target.id.coreID == coreID }.map { terminal in
                let subAgents = subAgentStatuses(of: terminal.target.address)
                let status = CoreTerminalInfo.treeStatus(own: appStates[terminal.target.address], subAgents: subAgents)
                let old = previous[coreID]?.terminals.first { $0.id == terminal.target.id }
                let updatedAt = old?.status == status ? old?.updatedAt ?? .distantPast
                    : old?.status == nil ? terminal.statusChangedAt ?? .distantPast : Date()
                return CoreTerminalInfo(target: terminal.target, title: terminal.title, status: status,
                                        cwd: terminal.cwd, updatedAt: updatedAt, online: online && terminal.online,
                                        workingSubAgents: status == nil ? 0 : subAgents.filter { $0 == .working }.count)
            }
            let retained = online ? records : (previous[coreID]?.terminals ?? records).map {
                var stale = $0
                stale.online = false
                return stale
            }
            let core = CoreSourceInfo(coreID: coreID, terminals: retained, online: online,
                                      error: online ? coreAppError : "Core machine is unavailable. Reconnect it in hc.", retryAt: nil)
            let index: Int?
            if machine == nil {
                index = next.firstIndex { $0.id == SourceDescriptor.local.id }
            } else {
                index = next.firstIndex { $0.descriptor.sshAlias == machine?.target && machine?.via == false }
            }
            if let index, next[index].core == nil {
                next[index].core = core
            } else {
                let descriptor = SourceDescriptor(id: "core:\(coreID)", name: machine?.name ?? "Core", sshAlias: nil)
                next.append(SourceInfo(descriptor: descriptor, sessions: [], online: false,
                                       error: nil, hasLegacy: false, core: core))
            }
        }
        sources = next.filter { $0.hasLegacy || $0.core != nil || $0.id == SourceDescriptor.local.id }
    }

    func retryCore() {
        guard let coreMonitor, pollingStarted else { return }
        Task {
            _ = await refreshCoreAppState(forceRefresh: true)
            await coreMonitor.retry()
        }
    }

    private func refreshBranches(for descriptor: SourceDescriptor, sessions: [SessionInfo], generation: UUID) {
        let paths = Self.branchPaths(from: sessions)
        guard !paths.isEmpty else { return }
        let branchGeneration = UUID()
        branchLoadGenerations[descriptor.id] = branchGeneration
        let loadBranches = self.loadBranches
        Task { [weak self] in
            let branches = await loadBranches(descriptor, paths)
            self?.applyBranches(
                branches,
                to: descriptor,
                monitorGeneration: generation,
                branchGeneration: branchGeneration
            )
        }
    }

    private func applyBranches(
        _ branches: [String: String],
        to descriptor: SourceDescriptor,
        monitorGeneration: UUID,
        branchGeneration: UUID
    ) {
        guard pollingStarted,
              monitorGenerations[descriptor.id] == monitorGeneration,
              branchLoadGenerations[descriptor.id] == branchGeneration,
              let index = sources.firstIndex(where: { $0.descriptor == descriptor })
        else { return }
        sources[index].branches = branches
        onChange?()
    }

    private func startRemoteMonitor(for descriptor: SourceDescriptor) {
        guard pollingStarted,
              descriptor.sshAlias != nil,
              remoteMonitors[descriptor.id] == nil,
              let remoteMonitorFactory
        else { return }
        let monitor = remoteMonitorFactory(descriptor)
        let generation = UUID()
        remoteMonitors[descriptor.id] = monitor
        monitorGenerations[descriptor.id] = generation
        pollFallbackSourceIDs.remove(descriptor.id)
        startMonitor(monitor, source: descriptor, generation: generation)
    }

    private func startMonitor(
        _ monitor: any SessionMonitoring,
        source descriptor: SourceDescriptor,
        generation: UUID
    ) {
        let sourceID = descriptor.id
        monitorStartTasks[sourceID]?.cancel()
        monitorStartTasks[sourceID] = Task { [weak self] in
            guard !Task.isCancelled,
                  let self,
                  self.pollingStarted,
                  self.monitorGenerations[sourceID] == generation
            else { return }
            await monitor.start { [weak self] event in
                await self?.handleMonitor(event, source: descriptor, generation: generation)
            }
            guard !Task.isCancelled,
                  self.pollingStarted,
                  self.monitorGenerations[sourceID] == generation
            else {
                await monitor.stop()
                return
            }
        }
    }

    private func markRemoteMonitorUnavailable(
        _ descriptor: SourceDescriptor,
        reason: String?,
        retryAt: Date?
    ) {
        guard monitorGenerations[descriptor.id] != nil,
              let index = sources.firstIndex(where: { $0.descriptor == descriptor })
        else { return }
        let failureCount = (sourceFailureCounts[descriptor.id] ?? 0) + 1
        sourceFailureCounts[descriptor.id] = failureCount
        var source = sources[index]
        source.online = false
        source.sessions = source.sessions.map {
            var stale = $0
            stale.online = false
            return stale
        }
        source.error = reason ?? (failureCount == 1 ? nil : "Unable to subscribe to Herdr on \(descriptor.name).")
        source.retryAt = retryAt
        sources[index] = source
        onChange?()
    }

    func retryRemoteSource(_ descriptor: SourceDescriptor) {
        guard descriptor.sshAlias != nil,
              monitorGenerations[descriptor.id] != nil,
              let monitor = remoteMonitors[descriptor.id],
              let index = sources.firstIndex(where: { $0.descriptor == descriptor })
        else { return }
        sources[index].error = nil
        sources[index].retryAt = .now
        onChange?()
        Task { await monitor.retry() }
    }

    func focus(_ agent: AgentInfo, in session: SessionInfo, source: SourceDescriptor = .local) {
        navigate(to: .agent(sourceID: source.id, sessionName: session.name, paneID: agent.paneID))
    }

    func focusWorkspace(_ group: AgentGroup, in session: SessionInfo, source: SourceDescriptor = .local) {
        navigate(to: .workspace(sourceID: source.id, sessionName: session.name, workspaceID: group.id))
    }

    func focusSession(_ session: SessionInfo, source: SourceDescriptor = .local) {
        navigate(to: .session(sourceID: source.id, sessionName: session.name))
    }

    func navigate(to destination: NavigationDestination) {
        guard acceptsNavigation else { return }
        let resolved = destination.resolve(in: sources)
        if resolved?.isAvailable == true, navigationAttempt?.phase == .pending,
           navigationAttempt?.destination == destination { return }
        navigationToken = UUID()
        let previous = navigationAttempt?.destination == destination ? navigationAttempt : nil
        let message = (resolved == nil ? NavigationValidationError.missing : .offline).localizedDescription
        navigationAttempt = NavigationAttempt(
            destination: destination,
            title: resolved?.title ?? previous?.title ?? destination.fallbackTitle,
            subtitle: resolved?.subtitle ?? previous?.subtitle ?? destination.identityDescription,
            phase: resolved?.isAvailable == true ? .pending : .failed,
            message: resolved?.isAvailable == true ? nil : message
        )
        focusError = navigationAttempt?.message
        guard let resolved, resolved.isAvailable else {
            onChange?()
            return
        }
        focusRunner.submit(FocusRequest(
            destination: destination, token: navigationToken,
            terminalApplication: terminalApplication, ghosttyOpenBehavior: ghosttyOpenBehavior
        ))
        onChange?()
    }

    func retryNavigation() {
        guard let navigationAttempt, navigationAttempt.phase == .failed else { return }
        navigate(to: navigationAttempt.destination)
    }

    func dismissFocusError() {
        focusError = nil
        if navigationAttempt?.phase == .failed { navigationAttempt = nil }
        onChange?()
    }

    private func performFocus(_ request: FocusRequest) async {
        guard request.token == navigationToken else { return }
        // Keep the error privacy boundary even if configuration disappears during the request.
        let initial = request.destination.resolve(in: sources)
        let remote = initial?.source.sshAlias != nil || initial?.coreTerminal.map {
            $0.target.id.coreID != $0.target.entryCoreID
        } == true
        defer { onChange?() }
        do {
            let resolved = try availableDestination(for: request)
            navigationAttempt = NavigationAttempt(
                destination: request.destination, title: resolved.title, subtitle: resolved.subtitle,
                phase: .pending, message: nil
            )
            switch request.destination {
            case .coreTerminal:
                try await performCoreFocus(request)
            case .agent, .workspace:
                guard let session = resolved.session else { throw NavigationValidationError.missing }
                // Public focus affects all shell clients and the target tab's seen state, even if
                // Terminal activation fails. The request token only gates Herdling's result UI.
                async let herdrFocus: Void = performHerdrFocus(request)
                let focusedExistingClient = try await focusExistingClient(resolved.source, session.name, request.terminalApplication)
                guard request.token == navigationToken else { return }
                _ = try availableDestination(for: request)
                try await herdrFocus
                guard request.token == navigationToken else { return }
                let latest = try availableDestination(for: request)
                guard let latestSession = latest.session else { throw NavigationValidationError.missing }
                if !focusedExistingClient {
                    try await activateClient(
                        latest.source,
                        latestSession.name,
                        try client.attachCommand(source: latest.source, session: latestSession.name),
                        request.terminalApplication,
                        request.ghosttyOpenBehavior
                    )
                    guard request.token == navigationToken else { return }
                    _ = try availableDestination(for: request)
                }
            case .session:
                guard let session = resolved.session else { throw NavigationValidationError.missing }
                let existing = try await focusExistingClient(resolved.source, session.name, request.terminalApplication)
                guard request.token == navigationToken else { return }
                let latest = try availableDestination(for: request)
                guard let latestSession = latest.session else { throw NavigationValidationError.missing }
                if !existing {
                    try await activateClient(
                        latest.source,
                        latestSession.name,
                        try client.attachCommand(source: latest.source, session: latestSession.name),
                        request.terminalApplication,
                        request.ghosttyOpenBehavior
                    )
                    guard request.token == navigationToken else { return }
                    _ = try availableDestination(for: request)
                }
            }
            completeNavigation(request.destination)
        } catch {
            guard request.token == navigationToken else { return }
            if case .coreTerminal = request.destination,
               !(error is NavigationValidationError),
               !(error is HerdrAppError)
            {
                focusError = "Core terminal could not be opened in Herdr App. Check Herdr App and Core, then retry."
            } else {
                focusError = Self.focusErrorMessage(error, remote: remote)
            }
            navigationAttempt?.phase = .failed
            navigationAttempt?.message = focusError
        }
    }

    private func performCoreFocus(_ request: FocusRequest) async throws {
        guard let target = try availableDestination(for: request).coreTerminal?.target else {
            throw NavigationValidationError.missing
        }
        try await focusCoreApp(target)
        _ = try availableDestination(for: request)
        guard await refreshCoreAppState(forceRefresh: true) else { throw HerdrCoreError.unavailable("Herdr App status is unavailable.") }
        _ = try availableDestination(for: request)
    }

    private func availableDestination(for request: FocusRequest) throws -> ResolvedNavigationDestination {
        guard request.token == navigationToken else { throw CancellationError() }
        guard let resolved = request.destination.resolve(in: sources) else { throw NavigationValidationError.missing }
        guard resolved.isAvailable else { throw NavigationValidationError.offline }
        return resolved
    }

    private func completeNavigation(_ destination: NavigationDestination) {
        navigationAttempt?.phase = .succeeded
        navigationAttempt?.message = nil
        if destination.isActivityTarget {
            successfulJumps.removeAll { $0 == destination }
            successfulJumps.insert(destination, at: 0)
            successfulJumps = Array(successfulJumps.prefix(3))
        }
        onClientActivated?()
    }

    private func pruneSuccessfulJumps() {
        successfulJumps.removeAll(where: hasDeparted)
    }

    private func hasDeparted(_ destination: NavigationDestination) -> Bool {
        if case let .coreTerminal(id) = destination {
            guard let core = sources.compactMap(\.core).first(where: { $0.coreID == id.coreID }) else { return true }
            return core.online && !core.terminals.contains { $0.id == id }
        }
        guard let source = sources.first(where: { $0.id == destination.sourceID }) else { return true }
        // An outage is not evidence that a session or pane identity exited.
        guard source.online else { return false }
        guard let session = source.sessions.first(where: { $0.name == destination.sessionName }) else { return true }
        guard session.online else { return false }
        return destination.resolve(in: sources) == nil
    }

    nonisolated static func focusErrorMessage(_ error: Error, remote: Bool = false) -> String {
        if let error = error as? NavigationValidationError { return error.localizedDescription }
        if let error = error as? HerdrAppError { return error.localizedDescription }
        if let error = error as? GhosttyController.GhosttyError {
            return error.localizedDescription
        }
        if let error = error as? KeroController.KeroError {
            return error.localizedDescription
        }
        if let error = error as? HerdrClient.ClientError {
            return switch error {
            case .notInstalled:
                "Herdr is not installed. Install Herdr or set HERDR_BIN_PATH, then retry."
            case .timedOut:
                remote
                    ? "Remote Herdr focus timed out. Check the session and SSH connection, then retry."
                    : "Herdr focus timed out. Check the session, then retry."
            case let .failed(message):
                if remote {
                    "Remote Herdr focus failed. Check the session and SSH connection, then retry."
                } else {
                    message.isEmpty ? "Herdr focus failed. Check the session, then retry." : "Herdr focus failed: \(message)"
                }
            case .invalidResponse:
                "Herdr returned an invalid response. Update Herdr, then retry."
            }
        }
        return "Could not open this item in the selected terminal. Try again."
    }

    func refreshSSHAliases(at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) async {
        let aliases = await Task.detached { SSHConfig.aliases(at: url) }.value
        guard !Task.isCancelled else { return }
        availableSSHAliases = aliases + selectedSSHAliases.filter { !aliases.contains($0) }
    }

    func setRemoteAlias(_ alias: String, enabled: Bool) {
        if enabled, availableSSHAliases.contains(alias), !selectedSSHAliases.contains(alias) {
            selectedSSHAliases.append(alias)
        }
        if !enabled { selectedSSHAliases.removeAll { $0 == alias } }
        selectedSSHAliases.sort { (availableSSHAliases.firstIndex(of: $0) ?? .max) < (availableSSHAliases.firstIndex(of: $1) ?? .max) }
        defaults.set(selectedSSHAliases, forKey: DefaultsKey.selectedSSHAliases)
        let old = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let descriptors = [SourceDescriptor.local] + selectedSSHAliases.map(SourceDescriptor.remote)
        let retainedIDs = Set(descriptors.map(\.id))
        pruneSourceRuntime(retainedIDs: retainedIDs)
        var next = descriptors.map { descriptor in
            var source = old[descriptor.id] ?? SourceInfo(descriptor: descriptor, sessions: [], online: false, error: nil)
            source.hasLegacy = legacyEnabled
            return source
        }
        for source in sources where !retainedIDs.contains(source.id) && source.core != nil {
            var retained = source
            retained.hasLegacy = false
            retained.sessions = []
            retained.error = nil
            next.append(retained)
        }
        sources = next
        for descriptor in descriptors where descriptor.sshAlias != nil {
            startRemoteMonitor(for: descriptor)
        }
        scheduleNextPoll(reset: true)
        onChange?()
        Task { await refresh() }
    }

    private func pruneSourceRuntime(retainedIDs: Set<String>) {
        sourceFailureCounts = sourceFailureCounts.filter { retainedIDs.contains($0.key) }
        branchLoadGenerations = branchLoadGenerations.filter { retainedIDs.contains($0.key) }
        pollFallbackSourceIDs.formIntersection(retainedIDs)
        for id in Set(remoteMonitors.keys).subtracting(retainedIDs) {
            let monitor = remoteMonitors.removeValue(forKey: id)
            let start = monitorStartTasks.removeValue(forKey: id)
            start?.cancel()
            monitorGenerations.removeValue(forKey: id)
            if let monitor {
                Task {
                    // The first stop unblocks a start that is still waiting on its handshake; the
                    // second one covers a start that re-armed the monitor after that stop.
                    await monitor.stop()
                    await start?.value
                    await monitor.stop()
                }
            }
        }
    }

    func setTerminalApplication(_ application: TerminalApplication) {
        guard terminalApplication != application else { return }
        terminalApplication = application
        defaults.set(application.rawValue, forKey: DefaultsKey.terminalApplication)
        terminalStatusRequest = nil
        terminalStatus = "Not checked"
    }

    func setGhosttyOpenBehavior(_ behavior: GhosttyOpenBehavior) {
        ghosttyOpenBehavior = behavior
        defaults.set(behavior.rawValue, forKey: DefaultsKey.ghosttyOpenBehavior)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try updateLoginItem(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = loadLoginItemStatus()
    }

    func refreshSettingsStatus() async {
        loginItemStatus = loadLoginItemStatus()
        await refreshTerminalStatus()
    }

    func refreshTerminalStatus() async {
        let application = terminalApplication
        let request = UUID()
        terminalStatusRequest = request
        let status = await loadTerminalStatus(application)
        guard terminalStatusRequest == request, terminalApplication == application, !Task.isCancelled else { return }
        terminalStatus = status
    }

    var pollInterval: Duration { .seconds(panelOpen ? 2 : 15) }

    private func scheduleNextPoll(reset: Bool = false) {
        guard pollingStarted, needsPolling else {
            guard pollTask != nil else { return }
            pollTask?.cancel()
            pollTask = nil
            pollGeneration += 1
            return
        }
        guard reset || pollTask == nil else { return }
        pollTask?.cancel()
        pollTask = nil
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

    private func monitorOwnsSource(_ id: String) -> Bool {
        monitorGenerations[id] != nil && !pollFallbackSourceIDs.contains(id)
    }

    private var needsPolling: Bool {
        sources.contains { source in
            guard source.hasLegacy else { return false }
            return !monitorOwnsSource(source.id)
        }
    }

    private func performHerdrFocus(_ request: FocusRequest) async throws {
        let resolved = try availableDestination(for: request)
        guard let session = resolved.session else { throw NavigationValidationError.missing }
        switch request.destination {
        case let .agent(_, _, paneID):
            try await runHerdrFocus(
                source: resolved.source,
                session: session.name,
                paneID: paneID,
                tabID: resolved.agent?.tabID
            )
        case let .workspace(_, _, workspaceID):
            let client = self.client
            try await Task.detached {
                try client.focusWorkspace(
                    source: resolved.source,
                    session: session.name,
                    workspaceID: workspaceID
                )
            }.value
        case .session, .coreTerminal:
            return
        }
    }

    private func runHerdrFocus(
        source: SourceDescriptor,
        session: String,
        paneID: String,
        tabID: String?
    ) async throws {
        let client = self.client
        try await Task.detached {
            try client.focus(source: source, session: session, paneID: paneID, tabID: tabID)
        }.value
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
                var previousAgents: [String: AgentInfo] = [:]
                for agent in old[item.name]?.agents ?? [] { previousAgents[agent.paneID] = agent }
                let groups = groups.map { group in
                    var group = group
                    group.agents = group.agents.map { agent in
                        var agent = agent
                        if let previous = previousAgents[agent.paneID], previous.status == agent.status {
                            agent.updatedAt = previous.updatedAt
                        }
                        return agent
                    }
                    return group
                }
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
