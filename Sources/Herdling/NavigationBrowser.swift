import Foundation
import Observation

enum NavigationRowID: Hashable {
    case source(String)
    case destination(NavigationDestination)
}

struct NavigationRowPresentation {
    let title: String
    let subtitle: String
    let status: AgentStatus?
    let available: Bool
}

@Observable
@MainActor
final class NavigationBrowser {
    enum Mode: Hashable { case quick, all }

    private(set) var mode: Mode = .quick
    private(set) var selection: NavigationRowID?
    private var keyboardDriven = false
    var keyboardSelection: NavigationRowID? { keyboardDriven ? selection : nil }
    var allowsPointerHighlight: Bool { !keyboardDriven }
    private var pointerSelection: NavigationRowID?
    @ObservationIgnored private var pointerLocation: CGPoint?
    var highlightedSelection: NavigationRowID? {
        keyboardDriven ? selection : pointerSelection
    }
    private(set) var expandedSourceID: String?
    private(set) var quickIDs: [NavigationDestination] = []
    private(set) var attempt: NavigationAttempt?
    private var latestSources: [SourceInfo]
    private var isOpen = false
    private struct Label { let title: String; let subtitle: String }
    private var labels: [NavigationDestination: Label] = [:]
    // Only topology and display labels are frozen. Runtime state always comes from latestSources.
    private struct GroupShape: Equatable {
        let id: String
        let name: String
        let panes: [String]
    }
    private struct SessionShape: Equatable {
        let name: String
        let groups: [GroupShape]
    }
    private struct SourceShape: Equatable {
        let descriptor: SourceDescriptor
        let sessions: [SessionShape]
        let hasLegacy: Bool
        let hasCore: Bool
        let coreID: String?
        let coreTargets: [CoreTerminalTarget]
    }
    private var topology: [SourceShape] = []

    var allSources: [SourceInfo] {
        topology.map { shape in
            let source = latestSources.first { $0.id == shape.descriptor.id }
            let sessions = shape.sessions.map { sessionShape in
                let session = source?.sessions.first { $0.name == sessionShape.name }
                let groups = sessionShape.groups.map { groupShape in
                    let agents = groupShape.panes.map { paneID in
                        if let live = session?.agents.first(where: { $0.paneID == paneID }) { return live }
                        let destination = NavigationDestination.agent(sourceID: shape.descriptor.id, sessionName: sessionShape.name, paneID: paneID)
                        return AgentInfo(paneID: paneID, title: labels[destination]?.title ?? paneID,
                                         status: .unknown, workspace: groupShape.name, cwd: "", updatedAt: .distantPast)
                    }
                    return AgentGroup(id: groupShape.id, name: groupShape.name, agents: agents)
                }
                return SessionInfo(name: sessionShape.name, groups: groups,
                                   online: source?.hasLegacy == true && source?.online == true && session?.online == true,
                                   updatedAt: session?.updatedAt, error: session?.error)
            }
            let core: CoreSourceInfo?
            if shape.hasCore {
                let current = shape.coreID.flatMap { id in
                    latestSources.compactMap(\.core).first { $0.coreID == id }
                } ?? (shape.coreID == nil ? source?.core : nil)
                core = CoreSourceInfo(coreID: shape.coreID, terminals: shape.coreTargets.map { target in
                    if let live = current?.terminals.first(where: { $0.id == target.id }) { return live }
                    return CoreTerminalInfo(target: target, title: labels[.coreTerminal(target.id)]?.title ?? target.address,
                                            status: nil, cwd: "", updatedAt: .distantPast, online: false)
                }, online: current?.online == true, error: current?.error, retryAt: current?.retryAt)
            } else { core = nil }
            return SourceInfo(descriptor: source?.descriptor ?? shape.descriptor, sessions: sessions,
                              online: source?.hasLegacy == true && source?.online == true,
                              error: source?.error ?? (source == nil ? "Source no longer available" : nil),
                              retryAt: source?.retryAt, branches: source?.branches ?? [:], hasLegacy: shape.hasLegacy, core: core)
        }
    }
    var recoveryTarget: NavigationDestination? {
        guard let attempt, attempt.phase == .pending || attempt.phase == .failed else { return nil }
        let regular = mode == .all ? directoryRows.map(\.id) : quickIDs.map(NavigationRowID.destination)
        return regular.contains(.destination(attempt.destination)) ? nil : attempt.destination
    }
    var offlineSourceNames: [String] {
        latestSources.flatMap { source in
            var names: [String] = []
            if source.hasLegacy && (!source.online || source.sessions.contains { !$0.online }) {
                names.append(source.descriptor.name + (source.core == nil ? "" : " / Herdr"))
            }
            if source.core?.online == false { names.append(source.descriptor.name + " / Core") }
            return names
        }
    }
    var quickCandidateCount: Int { candidates.count }
    var hasOnlineCoverage: Bool {
        latestSources.contains { source in
            source.core?.online == true || (source.hasLegacy && source.online &&
                (source.sessions.isEmpty || source.sessions.contains(where: \.online)))
        }
    }

    init(sources: [SourceInfo] = []) {
        latestSources = sources
        rebuildSnapshot()
    }

    func open(sources: [SourceInfo], attempt: NavigationAttempt?, expandedSourceID: String?) {
        latestSources = sources
        self.attempt = attempt
        self.expandedSourceID = RosterLayout.expandedSourceID(saved: expandedSourceID ?? "", available: sources.map(\.id))
        isOpen = true
        mode = .quick
        selection = nil
        keyboardDriven = false
        pointerSelection = nil
        pointerLocation = nil
        rebuildSnapshot()
    }

    func close() { isOpen = false; keyboardDriven = false; pointerSelection = nil }
    func receive(sources: [SourceInfo], attempt: NavigationAttempt?) {
        latestSources = sources
        self.attempt = attempt
        for destination in labels.keys {
            if let resolved = destination.resolve(in: sources) { labels[destination] = label(for: resolved) }
        }
        if !isOpen { rebuildSnapshot() }
        else { keepSelection() }
    }
    private func rebuildSnapshot() {
        quickIDs = candidates
        topology = shape(of: latestSources)
        expandedSourceID = RosterLayout.expandedSourceID(saved: expandedSourceID ?? "", available: latestSources.map(\.id))
        labels = [:]
        for destination in allDestinations {
            if let resolved = destination.resolve(in: latestSources) { labels[destination] = label(for: resolved) }
        }
        keepSelection()
    }
    func setMode(_ mode: Mode) { self.mode = mode; keepSelection() }
    func toggleSource(_ id: String) {
        guard topology.contains(where: { $0.descriptor.id == id }) else { return }
        expandedSourceID = expandedSourceID == id ? nil : id
        keepSelection()
    }
    func moveSelection(by direction: Int) {
        keyboardDriven = true
        let rows = visibleRows
        let step = direction < 0 ? -1 : 1
        var index = (selection.flatMap { rows.firstIndex(of: $0) } ?? (step > 0 ? -1 : rows.count)) + step
        while rows.indices.contains(index) {
            if canSelect(rows[index]) { selection = rows[index]; return }
            index += step
        }
    }
    func horizontal(_ direction: Int) {
        guard mode == .all, let selection else { return }
        keyboardDriven = true
        if case let .source(id) = selection {
            if direction > 0 { expandedSourceID = id }
            else if expandedSourceID == id { expandedSourceID = nil }
        } else if direction < 0 {
            self.selection = directoryRows.first { $0.id == selection }?.parent
        }
    }
    func activateSelection() -> NavigationDestination? {
        keyboardDriven = true
        pointerSelection = nil
        if case let .source(id) = selection { toggleSource(id); return nil }
        guard case let .destination(destination) = selection, isAvailable(destination) else { return nil }
        return destination
    }
    func clearSelection() { selection = nil; keyboardDriven = false; pointerSelection = nil }

    func holdPointer(at location: CGPoint) { pointerLocation = location }

    func selectFromPointer(_ row: NavigationRowID?, at location: CGPoint) {
        guard isOpen, location != pointerLocation else { return }
        pointerLocation = location
        keyboardDriven = false
        pointerSelection = row.flatMap { visibleRows.contains($0) && canSelect($0) ? $0 : nil }
        selection = pointerSelection
    }

    func pointerExited(_ row: NavigationRowID) {
        if pointerSelection == row { pointerSelection = nil }
    }

    func isAvailable(_ destination: NavigationDestination) -> Bool {
        destination.resolve(in: latestSources)?.isAvailable == true
    }

    func presentation(for destination: NavigationDestination) -> NavigationRowPresentation {
        let resolved = destination.resolve(in: latestSources)
        let currentLabel = resolved.map(label(for:)) ?? labels[destination]
        let recovery = attempt?.destination == destination ? attempt : nil
        return NavigationRowPresentation(
            title: currentLabel?.title ?? recovery?.title ?? destination.fallbackTitle,
            subtitle: currentLabel?.subtitle ?? recovery?.subtitle ?? destination.sourceID,
            status: resolved?.agent?.status ?? resolved?.coreTerminal?.status,
            available: resolved?.isAvailable == true
        )
    }

    private func label(for resolved: ResolvedNavigationDestination) -> Label {
        if resolved.coreTerminal != nil { return Label(title: resolved.title, subtitle: resolved.subtitle) }
        let ambiguous = resolved.agent.map { agent in resolved.group?.agents.count { $0.title == agent.title } ?? 0 } ?? 0
        let pane = ambiguous > 1 ? resolved.agent.map { " / \($0.paneID)" } ?? "" : ""
        let parts = [resolved.source.sshAlias == nil ? nil : resolved.source.name,
                     "Herdr",
                     resolved.session?.name == "default" ? nil : resolved.session?.name,
                     resolved.group?.name].compactMap { $0 }
        return Label(title: resolved.title, subtitle: (parts.isEmpty ? resolved.source.name : parts.joined(separator: " / ")) + pane)
    }

    private var visibleRows: [NavigationRowID] {
        var rows = mode == .all ? directoryRows.map(\.id) : quickIDs.map(NavigationRowID.destination)
        if let recoveryTarget { rows.append(.destination(recoveryTarget)) }
        return rows
    }
    private func canSelect(_ row: NavigationRowID) -> Bool {
        switch row {
        case .source: true
        case let .destination(destination): isAvailable(destination)
        }
    }
    private func keepSelection() {
        if let selection, !visibleRows.contains(selection) { self.selection = nil }
        if let pointerSelection, !visibleRows.contains(pointerSelection) { self.pointerSelection = nil }
    }

    private func shape(of sources: [SourceInfo]) -> [SourceShape] {
        sources.map { source in
            SourceShape(descriptor: source.descriptor, sessions: source.sessions.map { session in
                SessionShape(name: session.name, groups: session.groups.map {
                    GroupShape(id: $0.id, name: $0.name, panes: $0.agents.map(\.paneID))
                })
            }, hasLegacy: source.hasLegacy, hasCore: source.core != nil, coreID: source.core?.coreID,
                        coreTargets: source.core?.terminals.map(\.target) ?? [])
        }
    }

    private var allDestinations: [NavigationDestination] {
        var result: [NavigationDestination] = []
        for source in latestSources {
            for session in source.sessions {
                result.append(.session(sourceID: source.id, sessionName: session.name))
                for group in session.groups {
                    result.append(.workspace(sourceID: source.id, sessionName: session.name, workspaceID: group.id))
                    result += group.agents.map { .agent(sourceID: source.id, sessionName: session.name, paneID: $0.paneID) }
                }
            }
            result += source.core?.terminals.map { .coreTerminal($0.id) } ?? []
        }
        return result
    }

    private struct DirectoryRow { let id: NavigationRowID; let parent: NavigationRowID? }
    private var directoryRows: [DirectoryRow] {
        var result: [DirectoryRow] = []
        for source in allSources {
            let sourceRow = NavigationRowID.source(source.id)
            result.append(DirectoryRow(id: sourceRow, parent: nil))
            guard source.id == expandedSourceID else { continue }
            for session in source.sessions {
                let sessionRow = NavigationRowID.destination(.session(sourceID: source.id, sessionName: session.name))
                let showsHeader = RosterLayout.showsSessionHeader(name: session.name, sourceSessionCount: source.sessions.count)
                if showsHeader || (session.groups.isEmpty && session.online) {
                    result.append(DirectoryRow(id: sessionRow, parent: sourceRow))
                }
                let parent = showsHeader ? sessionRow : sourceRow
                for space in RosterLayout.spaces(from: session.groups) {
                    for worktree in space.displayedWorktrees() {
                        let group = worktree.group
                        let workspaceRow = NavigationRowID.destination(.workspace(sourceID: source.id, sessionName: session.name, workspaceID: group.id))
                        result.append(DirectoryRow(id: workspaceRow, parent: parent))
                        for agent in group.agents {
                            let agentRow = NavigationRowID.destination(.agent(sourceID: source.id, sessionName: session.name, paneID: agent.paneID))
                            result.append(DirectoryRow(id: agentRow, parent: workspaceRow))
                        }
                    }
                }
            }
            for terminal in source.core?.terminals ?? [] {
                result.append(DirectoryRow(id: .destination(.coreTerminal(terminal.id)), parent: sourceRow))
            }
        }
        return result
    }

    private var candidates: [NavigationDestination] {
        func rank(_ status: AgentStatus) -> Int {
            switch status {
            case .blocked: 0
            case .error: 1
            case .done: 2
            case .working: 3
            case .idle: 4
            case .unknown: 5
            }
        }
        let records = latestSources.flatMap { source -> [(NavigationDestination, AgentStatus, Date)] in
            var records = source.sessions.flatMap { session in
                session.agents.compactMap { agent -> (NavigationDestination, AgentStatus, Date)? in
                    let destination = NavigationDestination.agent(sourceID: source.id, sessionName: session.name, paneID: agent.paneID)
                    guard source.hasLegacy && source.online && session.online && agent.status != .unknown else { return nil }
                    return (destination, agent.status, agent.updatedAt)
                }
            }
            if let core = source.core, core.online {
                records += core.terminals.compactMap { terminal in
                    guard terminal.online, let status = terminal.status, status != .unknown else { return nil }
                    return (.coreTerminal(terminal.id), status, terminal.updatedAt)
                }
            }
            return records
        }
        var idleCount = 0
        return records.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            let priorityA = rank(a.1), priorityB = rank(b.1)
            if priorityA != priorityB { return priorityA < priorityB }
            if a.2 != b.2 { return a.2 > b.2 }
            return left.offset < right.offset
        }.filter { record in
            guard record.element.1 == .idle else { return true }
            idleCount += 1
            return idleCount <= 3
        }.map { $0.element.0 }
    }
}
