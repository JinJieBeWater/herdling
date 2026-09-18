import Foundation
import Observation
import ServiceManagement

private enum DefaultsKey {
    static let selectedSSHAliases = "selected-ssh-aliases"
    static let ghosttyOpenBehavior = "ghostty-open-behavior"
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

private enum FocusRequest: Sendable {
    case agent(AgentInfo, SessionInfo, SourceDescriptor)
    case workspace(String, SessionInfo, SourceDescriptor)
    case session(SessionInfo, SourceDescriptor)

    var source: SourceDescriptor {
        switch self {
        case let .agent(_, _, source), let .workspace(_, _, source), let .session(_, source): source
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

struct RecentAgentItem: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let sourceID: String
        let sessionName: String
        let paneID: String
    }

    let id: ID
    let agent: AgentInfo
}

enum RecentAgentList {
    static let idleLifetime: TimeInterval = 10 * 60

    private struct SessionSelection {
        var rankByGroupName: [String: Int] = [:]
        var rankByPaneID: [String: Int] = [:]
    }

    private struct SourceSelection {
        var sessionOrder: [String] = []
        var sessions: [String: SessionSelection] = [:]
    }

    /// Ranking bookkeeping for the outline: sources and sessions keep the order in which their first
    /// item appeared, groups and panes keep the item order inside them.
    private struct OutlineOrder {
        private var sourceOrder: [String] = []
        private var selections: [String: SourceSelection] = [:]

        var sourceIDs: [String] { sourceOrder }

        mutating func add(_ item: RecentAgentItem, rank: Int) {
            let sourceID = item.id.sourceID
            let sessionName = item.id.sessionName
            if selections[sourceID] == nil {
                sourceOrder.append(sourceID)
                selections[sourceID] = SourceSelection()
            }

            var sourceSelection = selections[sourceID]!
            if sourceSelection.sessions[sessionName] == nil {
                sourceSelection.sessionOrder.append(sessionName)
                sourceSelection.sessions[sessionName] = SessionSelection()
            }

            var sessionSelection = sourceSelection.sessions[sessionName]!
            let components = item.agent.workspace.split(separator: "/")
            for end in components.indices {
                let name = components[...end].joined(separator: "/")
                sessionSelection.rankByGroupName[name] = min(
                    sessionSelection.rankByGroupName[name] ?? rank,
                    rank
                )
            }
            if sessionSelection.rankByPaneID[item.id.paneID] == nil {
                sessionSelection.rankByPaneID[item.id.paneID] = rank
            }
            sourceSelection.sessions[sessionName] = sessionSelection
            selections[sourceID] = sourceSelection
        }

        /// Returns nil when the source contributed no ranked item, so the caller skips it.
        func sessions(for source: SourceInfo) -> [SessionInfo]? {
            guard let selection = selections[source.id] else { return nil }
            let sessionByName = Dictionary(uniqueKeysWithValues: source.sessions.map { ($0.name, $0) })

            return selection.sessionOrder.compactMap { sessionName -> SessionInfo? in
                guard let session = sessionByName[sessionName],
                      let sessionSelection = selection.sessions[sessionName]
                else { return nil }

                let groups = session.groups.enumerated().compactMap { index, group -> (Int, Int, AgentGroup)? in
                    let agents = group.agents
                        .filter { sessionSelection.rankByPaneID[$0.paneID] != nil }
                        .sorted {
                            sessionSelection.rankByPaneID[$0.paneID, default: .max]
                                < sessionSelection.rankByPaneID[$1.paneID, default: .max]
                        }
                    guard let rank = sessionSelection.rankByGroupName[group.name] else { return nil }
                    return (rank, index, AgentGroup(id: group.id, name: group.name, agents: agents))
                }.sorted {
                    $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
                }.map(\.2)

                return SessionInfo(
                    name: session.name,
                    groups: groups,
                    online: session.online,
                    updatedAt: session.updatedAt,
                    error: session.error
                )
            }
        }
    }

    /// Idle agents to fall back on when nothing has been active recently, most recently updated
    /// first, so the section still leads somewhere.
    static func idleFallback(from sources: [SourceInfo], limit: Int = 3) -> [RecentAgentItem] {
        var candidates: [(order: Int, agent: AgentInfo, source: SourceInfo, sessionName: String)] = []
        var order = 0
        for source in sources where source.online {
            for session in source.sessions where session.online {
                for agent in session.agents where agent.status == .idle {
                    candidates.append((order, agent, source, session.name))
                    order += 1
                }
            }
        }

        return candidates
            .sorted {
                if $0.agent.updatedAt != $1.agent.updatedAt {
                    return $0.agent.updatedAt > $1.agent.updatedAt
                }
                return $0.order < $1.order
            }
            .prefix(limit)
            .map {
                RecentAgentItem(
                    id: .init(
                        sourceID: $0.source.id,
                        sessionName: $0.sessionName,
                        paneID: $0.agent.paneID
                    ),
                    agent: $0.agent
                )
            }
    }

    static func items(from sources: [SourceInfo], at now: Date) -> [RecentAgentItem] {
        var order = 0
        var ranked: [(priority: Int, order: Int, item: RecentAgentItem)] = []

        for source in sources where source.online {
            for session in source.sessions where session.online {
                for agent in session.agents {
                    let originalOrder = order
                    order += 1
                    guard let priority = priority(for: agent, at: now) else { continue }
                    ranked.append((
                        priority,
                        originalOrder,
                        RecentAgentItem(
                            id: .init(
                                sourceID: source.id,
                                sessionName: session.name,
                                paneID: agent.paneID
                            ),
                            agent: agent
                        )
                    ))
                }
            }
        }

        return ranked.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.item.agent.updatedAt != $1.item.agent.updatedAt {
                return $0.item.agent.updatedAt > $1.item.agent.updatedAt
            }
            return $0.order < $1.order
        }.map(\.item)
    }

    static func outlineSources(from sources: [SourceInfo], items: [RecentAgentItem]) -> [SourceInfo] {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var order = OutlineOrder()
        for (rank, item) in items.enumerated() {
            order.add(item, rank: rank)
        }

        return order.sourceIDs.compactMap { sourceID -> SourceInfo? in
            guard let source = sourceByID[sourceID],
                  let sessions = order.sessions(for: source)
            else { return nil }

            return SourceInfo(
                descriptor: source.descriptor,
                sessions: sessions,
                online: source.online,
                error: source.error,
                retryAt: source.retryAt,
                branches: source.branches
            )
        }
    }

    private static func priority(for agent: AgentInfo, at now: Date) -> Int? {
        switch agent.status {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle:
            (0..<idleLifetime).contains(now.timeIntervalSince(agent.updatedAt)) ? 3 : nil
        case .unknown: nil
        }
    }
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
    struct WorkspaceFocusID: Equatable {
        let sourceID: String
        let sessionName: String
        let workspaceID: String
    }

    typealias SourceLoader = @Sendable (SourceDescriptor) async throws -> [HerdrClient.LoadedSession]
    typealias BranchLoader = @Sendable (SourceDescriptor, [String]) async -> [String: String]
    typealias RemoteMonitorFactory = @Sendable (SourceDescriptor) -> any SessionMonitoring

    private let client: HerdrClient
    private let loadSource: SourceLoader
    private let loadBranches: BranchLoader
    private let ghostty: GhosttyController
    private let focusExistingClient: @Sendable (SourceDescriptor, String) async throws -> Bool
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

    private(set) var sources: [SourceInfo]
    private(set) var availableSSHAliases: [String]
    private(set) var selectedSSHAliases: [String]
    private(set) var focusError: String?
    private var pendingFocus: FocusRequest?

    var pendingFocusAgentID: RecentAgentItem.ID? {
        guard case let .agent(agent, session, source) = pendingFocus else { return nil }
        return RecentAgentItem.ID(
            sourceID: source.id,
            sessionName: session.name,
            paneID: agent.paneID
        )
    }

    var pendingFocusWorkspaceID: WorkspaceFocusID? {
        guard case let .workspace(workspaceID, session, source) = pendingFocus else { return nil }
        return WorkspaceFocusID(
            sourceID: source.id,
            sessionName: session.name,
            workspaceID: workspaceID
        )
    }
    private(set) var settingsError: String?
    private(set) var automationStatus = "Not checked"
    private(set) var ghosttyOpenBehavior: GhosttyOpenBehavior
    private var isRefreshing = false
    private(set) var panelOpen = false
    private(set) var showingSettings = false

    var menuStatus: MenuStatus { MenuStatus.summarize(sources) }
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func recentAgents(at date: Date) -> [RecentAgentItem] {
        RecentAgentList.items(from: sources, at: date)
    }

    /// What the Recent section shows when nothing has been active lately: a few idle agents, so the
    /// section still leads somewhere instead of sitting empty.
    func recentFallbackAgents() -> [RecentAgentItem] {
        RecentAgentList.idleFallback(from: sources)
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
        loadSource: SourceLoader? = nil,
        loadBranches: BranchLoader? = nil,
        localMonitor: (any SessionMonitoring)? = nil,
        remoteMonitorFactory: RemoteMonitorFactory? = nil,
        focusExistingClient: (@Sendable (SourceDescriptor, String) async throws -> Bool)? = nil,
        sourceDescriptors: [SourceDescriptor]? = nil,
        defaults: UserDefaults = .standard
    ) {
        let persisted = defaults.stringArray(forKey: DefaultsKey.selectedSSHAliases) ?? []
        let aliases = sourceDescriptors?.compactMap(\.sshAlias) ?? SSHConfig.aliases()
        let selected = sourceDescriptors?.compactMap(\.sshAlias) ?? aliases.filter(persisted.contains)
        let ghostty = GhosttyController()
        self.client = client
        self.loadSource = loadSource ?? { try await client.load($0) }
        self.loadBranches = loadBranches ?? { source, paths in
            await GitBranchResolver.shared.branches(source: source, paths: paths)
        }
        self.sleep = sleep
        self.localMonitor = localMonitor
        self.remoteMonitorFactory = remoteMonitorFactory
        self.ghostty = ghostty
        self.focusExistingClient = focusExistingClient ?? { source, session in
            try await ghostty.focusExistingClient(source: source, session: session)
        }
        self.defaults = defaults
        availableSSHAliases = aliases
        selectedSSHAliases = selected
        ghosttyOpenBehavior = GhosttyOpenBehavior(
            rawValue: defaults.string(forKey: DefaultsKey.ghosttyOpenBehavior) ?? ""
        ) ?? .tab
        if sourceDescriptors == nil, selected != persisted {
            defaults.set(selected, forKey: DefaultsKey.selectedSSHAliases)
        }
        let descriptors = sourceDescriptors ?? ([SourceDescriptor.local] + selected.map(SourceDescriptor.remote))
        sources = descriptors.map { SourceInfo(descriptor: $0, sessions: [], online: false, error: nil) }
    }

    func start() {
        guard !pollingStarted else { return }
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

    func setShowingSettings(_ showing: Bool) {
        showingSettings = showing
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
        guard session.online else { return }
        focusError = nil
        pendingFocus = .agent(agent, session, source)
        focusRunner.submit(.agent(agent, session, source))
    }

    func focusWorkspace(_ group: AgentGroup, in session: SessionInfo, source: SourceDescriptor = .local) {
        guard session.online else { return }
        focusError = nil
        pendingFocus = .workspace(group.id, session, source)
        focusRunner.submit(.workspace(group.id, session, source))
    }

    func focusSession(_ session: SessionInfo, source: SourceDescriptor = .local) {
        guard session.online else { return }
        focusError = nil
        pendingFocus = nil
        focusRunner.submit(.session(session, source))
    }

    func dismissFocusError() {
        focusError = nil
    }

    private func performFocus(_ request: FocusRequest) async {
        focusError = nil
        defer {
            if !focusRunner.hasPendingRequest {
                pendingFocus = nil
            }
            onChange?()
        }

        guard sources.contains(where: { $0.descriptor == request.source }) else { return }

        do {
            switch request {
            case let .agent(_, session, source), let .workspace(_, session, source):
                // Herdr 0.9 projects workspace/tab/pane focus onto every attached client, so the CLI
                // call can run while the Ghostty window is located and raised; a client created
                // afterwards attaches to the focus already set on the server.
                async let herdrFocus: Void = performHerdrFocus(
                    request,
                    source: source,
                    session: session
                )
                let focusedExistingClient = try await focusExistingClient(source, session.name)
                guard !focusRunner.hasPendingRequest else { return }
                try await herdrFocus
                guard !focusRunner.hasPendingRequest else { return }
                if !focusedExistingClient {
                    try await ghostty.activateClient(
                        source: source,
                        session: session.name,
                        command: try client.attachCommand(source: source, session: session.name),
                        openBehavior: ghosttyOpenBehavior
                    )
                }
                onClientActivated?()
            case let .session(session, source):
                try await ghostty.activateClient(
                    source: source,
                    session: session.name,
                    command: try client.attachCommand(source: source, session: session.name),
                    openBehavior: ghosttyOpenBehavior
                )
                onClientActivated?()
            }
        } catch {
            if !focusRunner.hasPendingRequest {
                focusError = Self.focusErrorMessage(error, remote: request.source.sshAlias != nil)
            }
        }
    }

    nonisolated static func focusErrorMessage(_ error: Error, remote: Bool = false) -> String {
        if let error = error as? GhosttyController.GhosttyError {
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
        return "Could not open this item in Ghostty. Try again."
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

    func setGhosttyOpenBehavior(_ behavior: GhosttyOpenBehavior) {
        ghosttyOpenBehavior = behavior
        defaults.set(behavior.rawValue, forKey: DefaultsKey.ghosttyOpenBehavior)
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

    private func performHerdrFocus(
        _ request: FocusRequest,
        source: SourceDescriptor,
        session: SessionInfo
    ) async throws {
        switch request {
        case let .agent(agent, _, _):
            try await runHerdrFocus(
                source: source,
                session: session.name,
                paneID: agent.paneID,
                tabID: agent.tabID
            )
        case let .workspace(workspaceID, _, _):
            let client = self.client
            try await Task.detached {
                try client.focusWorkspace(
                    source: source,
                    session: session.name,
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
                        } else if previousAgents[agent.paneID] == nil, agent.status == .idle {
                            agent.updatedAt = .distantPast
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
