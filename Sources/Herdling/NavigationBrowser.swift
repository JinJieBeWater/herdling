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
                return SessionInfo(name: sessionShape.name, groups: groups, online: source?.online == true && session?.online == true,
                                   updatedAt: session?.updatedAt, error: session?.error)
            }
            return SourceInfo(descriptor: source?.descriptor ?? shape.descriptor, sessions: sessions,
                              online: source?.online == true, error: source?.error ?? (source == nil ? "Source no longer available" : nil),
                              retryAt: source?.retryAt, branches: source?.branches ?? [:])
        }
    }
    var recoveryTarget: NavigationDestination? {
        guard let attempt, attempt.phase == .pending || attempt.phase == .failed else { return nil }
        let regular = mode == .all ? directoryRows.map(\.id) : quickIDs.map(NavigationRowID.destination)
        return regular.contains(.destination(attempt.destination)) ? nil : attempt.destination
    }
    var offlineSourceNames: [String] { latestSources.filter { !$0.online || $0.sessions.contains { !$0.online } }.map(\.descriptor.name) }
    var quickCandidateCount: Int { candidates.count }
    var hasOnlineCoverage: Bool {
        latestSources.contains { $0.online && ($0.sessions.isEmpty || $0.sessions.contains(where: \.online)) }
    }

    init(sources: [SourceInfo] = []) {
        latestSources = sources
        rebuildSnapshot()
    }

    func open(sources: [SourceInfo], attempt: NavigationAttempt?, keyboard: Bool, expandedSourceID: String?) {
        latestSources = sources
        self.attempt = attempt
        self.expandedSourceID = RosterLayout.expandedSourceID(saved: expandedSourceID ?? "", available: sources.map(\.id))
        isOpen = true
        mode = .quick
        selection = nil
        keyboardDriven = keyboard
        pointerSelection = nil
        pointerLocation = nil
        rebuildSnapshot()
        if keyboard { selection = visibleRows.first(where: canSelect) }
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
            title: currentLabel?.title ?? recovery?.title ?? destination.sessionName,
            subtitle: currentLabel?.subtitle ?? recovery?.subtitle ?? destination.sourceID,
            status: resolved?.agent?.status,
            available: resolved?.isAvailable == true
        )
    }

    private func label(for resolved: ResolvedNavigationDestination) -> Label {
        let ambiguous = resolved.agent.map { agent in resolved.group?.agents.count { $0.title == agent.title } ?? 0 } ?? 0
        let pane = ambiguous > 1 ? resolved.agent.map { " / \($0.paneID)" } ?? "" : ""
        let parts = [resolved.source.sshAlias == nil ? nil : resolved.source.name,
                     resolved.session.name == "default" ? nil : resolved.session.name,
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
            })
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
        }
        return result
    }

    private var candidates: [NavigationDestination] {
        func rank(_ status: AgentStatus) -> Int {
            switch status {
            case .blocked: 0
            case .done: 1
            case .working: 2
            case .idle: 3
            case .unknown: 4
            }
        }
        let records = latestSources.flatMap { source in
            source.sessions.flatMap { session in
                session.agents.compactMap { agent -> (NavigationDestination, AgentInfo)? in
                    let destination = NavigationDestination.agent(sourceID: source.id, sessionName: session.name, paneID: agent.paneID)
                    guard source.online && session.online && agent.status != .unknown else { return nil }
                    return (destination, agent)
                }
            }
        }
        var idleCount = 0
        return records.enumerated().sorted { left, right in
            let a = left.element.1, b = right.element.1
            let priorityA = rank(a.status), priorityB = rank(b.status)
            if priorityA != priorityB { return priorityA < priorityB }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return left.offset < right.offset
        }.filter { record in
            guard record.element.1.status == .idle else { return true }
            idleCount += 1
            return idleCount <= 3
        }.map { $0.element.0 }
    }
}
