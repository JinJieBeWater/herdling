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
        let onlineSources = sources.filter(\.online)
        guard !onlineSources.isEmpty else {
            return Self(
                counts: [],
                availability: sources.contains { $0.error == nil } ? .loading : .offline
            )
        }
        let agents = onlineSources.flatMap { $0.sessions.filter(\.online).flatMap(\.agents) }
            .filter { $0.status != .unknown }
        return Self(counts: AgentStatusCount.summarize(agents), availability: .online)
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

    private let client: HerdrClient
    private let loadSource: SourceLoader
    private let loadBranches: BranchLoader
    private let focusExistingClient: ExistingClientFocus
    private let activateClient: ClientActivation
    private let loadTerminalStatus: TerminalStatusLoader
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
        self.init(
            client: HerdrClient(),
            localMonitor: HerdrLocalSessionMonitor(),
            remoteMonitorFactory: { HerdrRemoteSessionMonitor(source: $0) }
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
        activateClient: ClientActivation? = nil
    ) {
        let persisted = defaults.stringArray(forKey: DefaultsKey.selectedSSHAliases) ?? []
        let aliases = sourceDescriptors?.compactMap(\.sshAlias) ?? SSHConfig.aliases()
        let selected = sourceDescriptors?.compactMap(\.sshAlias) ?? aliases.filter(persisted.contains)
        let kero = KeroController()
        let ghostty = GhosttyController()
        self.client = client
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
        sources = descriptors.map { SourceInfo(descriptor: $0, sessions: [], online: false, error: nil) }
    }

    func start() {
        guard !pollingStarted else { return }
        acceptsNavigation = true
        pollingStarted = true
        if let localMonitor {
            let generation = UUID()
            monitorGenerations[SourceDescriptor.local.id] = generation
            startMonitor(localMonitor, source: .local, generation: generation)
        }
        for descriptor in sources.map(\.descriptor) where descriptor.sshAlias != nil {
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
        starts: [Task<Void, Never>]
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
        return (localMonitor, monitors, starts)
    }

    private func finishStopping(_ plan: (
        local: (any SessionMonitoring)?,
        remotes: [any SessionMonitoring],
        starts: [Task<Void, Never>]
    )) async {
        let monitors = [plan.local].compactMap { $0 } + plan.remotes
        // Stop once up front, then once more after the starts settle: a monitor whose start() was
        // already in flight re-arms itself when it finishes, so the trailing stop is the one that
        // guarantees it stays down. StopCount >= 2 is asserted by the race test.
        let stops = monitors.map { monitor in Task { await monitor.stop() } }
        for start in plan.starts { await start.value }
        for stop in stops { await stop.value }
        for monitor in monitors { await monitor.stop() }
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
        let descriptors = sources.map(\.descriptor).filter { !monitorOwnsSource($0.id) }
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
        let fallbackTitle = switch destination {
        case let .agent(_, _, paneID): paneID
        case let .workspace(_, _, workspaceID): workspaceID
        case let .session(_, sessionName): sessionName
        }
        navigationAttempt = NavigationAttempt(
            destination: destination,
            title: resolved?.title ?? previous?.title ?? fallbackTitle,
            subtitle: resolved?.subtitle ?? previous?.subtitle ?? "\(destination.sourceID) / \(destination.sessionName)",
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
        let remote = request.destination.resolve(in: sources)?.source.sshAlias != nil
        defer { onChange?() }
        do {
            let resolved = try availableDestination(for: request)
            navigationAttempt = NavigationAttempt(
                destination: request.destination, title: resolved.title, subtitle: resolved.subtitle,
                phase: .pending, message: nil
            )
            switch request.destination {
            case .agent, .workspace:
                // Public focus affects all shell clients and the target tab's seen state, even if
                // Terminal activation fails. The request token only gates Herdling's result UI.
                async let herdrFocus: Void = performHerdrFocus(request)
                let focusedExistingClient = try await focusExistingClient(resolved.source, resolved.session.name, request.terminalApplication)
                guard request.token == navigationToken else { return }
                _ = try availableDestination(for: request)
                try await herdrFocus
                guard request.token == navigationToken else { return }
                let latest = try availableDestination(for: request)
                if !focusedExistingClient {
                    try await activateClient(
                        latest.source,
                        latest.session.name,
                        try client.attachCommand(source: latest.source, session: latest.session.name),
                        request.terminalApplication,
                        request.ghosttyOpenBehavior
                    )
                    guard request.token == navigationToken else { return }
                    _ = try availableDestination(for: request)
                }
            case .session:
                let existing = try await focusExistingClient(resolved.source, resolved.session.name, request.terminalApplication)
                guard request.token == navigationToken else { return }
                let latest = try availableDestination(for: request)
                if !existing {
                    try await activateClient(
                        latest.source,
                        latest.session.name,
                        try client.attachCommand(source: latest.source, session: latest.session.name),
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
            focusError = Self.focusErrorMessage(error, remote: remote)
            navigationAttempt?.phase = .failed
            navigationAttempt?.message = focusError
        }
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
        if case .agent = destination {
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
        guard let source = sources.first(where: { $0.id == destination.sourceID }) else { return true }
        // An outage is not evidence that a session or pane identity exited.
        guard source.online else { return false }
        guard let session = source.sessions.first(where: { $0.name == destination.sessionName }) else { return true }
        guard session.online else { return false }
        return destination.resolve(in: sources) == nil
    }

    nonisolated static func focusErrorMessage(_ error: Error, remote: Bool = false) -> String {
        if let error = error as? NavigationValidationError { return error.localizedDescription }
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
        sources = descriptors.map { old[$0.id] ?? SourceInfo(descriptor: $0, sessions: [], online: false, error: nil) }
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
            !monitorOwnsSource(source.id)
        }
    }

    private func performHerdrFocus(_ request: FocusRequest) async throws {
        let resolved = try availableDestination(for: request)
        switch request.destination {
        case let .agent(_, _, paneID):
            try await runHerdrFocus(
                source: resolved.source,
                session: resolved.session.name,
                paneID: paneID,
                tabID: resolved.agent?.tabID
            )
        case let .workspace(_, _, workspaceID):
            let client = self.client
            try await Task.detached {
                try client.focusWorkspace(
                    source: resolved.source,
                    session: resolved.session.name,
                    workspaceID: workspaceID
                )
            }.value
        case .session:
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
