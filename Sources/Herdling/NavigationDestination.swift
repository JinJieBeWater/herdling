import Foundation

enum NavigationDestination: Hashable, Sendable {
    case agent(sourceID: String, sessionName: String, paneID: String)
    case workspace(sourceID: String, sessionName: String, workspaceID: String)
    case session(sourceID: String, sessionName: String)
    case coreTerminal(CoreTerminalID)

    var agentFocusID: AgentFocusID? {
        guard case let .agent(sourceID, sessionName, paneID) = self else { return nil }
        return AgentFocusID(sourceID: sourceID, sessionName: sessionName, paneID: paneID)
    }

    var sourceID: String {
        switch self {
        case let .agent(sourceID, _, _), let .workspace(sourceID, _, _), let .session(sourceID, _):
            sourceID
        case let .coreTerminal(id): "core:\(id.coreID)"
        }
    }

    var sessionName: String? {
        switch self {
        case let .agent(_, sessionName, _), let .workspace(_, sessionName, _), let .session(_, sessionName):
            sessionName
        case .coreTerminal: nil
        }
    }

    var isActivityTarget: Bool {
        switch self {
        case .agent, .coreTerminal: true
        case .workspace, .session: false
        }
    }

    var identityDescription: String {
        switch self {
        case let .agent(source, session, pane): "Source \(source), session \(session), pane \(pane)"
        case let .workspace(source, session, workspace): "Source \(source), session \(session), workspace \(workspace)"
        case let .session(source, session): "Source \(source), session \(session)"
        case let .coreTerminal(id): "Core \(id.coreID), terminal \(id.terminalID)"
        }
    }

    var fallbackTitle: String {
        switch self {
        case let .agent(_, _, pane): pane
        case let .workspace(_, _, workspace): workspace
        case let .session(_, session): session
        case let .coreTerminal(id): id.terminalID
        }
    }

    func resolve(in sources: [SourceInfo]) -> ResolvedNavigationDestination? {
        if case let .coreTerminal(id) = self {
            for source in sources {
                guard let core = source.core,
                      let terminal = core.terminals.first(where: { $0.id == id }) else { continue }
                return ResolvedNavigationDestination(
                    destination: self, source: source.descriptor, session: nil, agent: nil, group: nil,
                    isAvailable: core.online && terminal.online, title: terminal.title,
                    subtitle: "\(source.descriptor.name) / Core / \(terminal.target.address)", coreTerminal: terminal
                )
            }
            return nil
        }
        guard let source = sources.first(where: { $0.id == sourceID }),
              source.hasLegacy,
              let session = source.sessions.first(where: { $0.name == sessionName })
        else { return nil }
        let agent: AgentInfo?
        let group: AgentGroup?
        let title: String
        switch self {
        case let .agent(_, _, paneID):
            guard let containingGroup = session.groups.first(where: { $0.agents.contains { $0.paneID == paneID } }),
                  let target = containingGroup.agents.first(where: { $0.paneID == paneID })
            else { return nil }
            agent = target
            group = containingGroup
            title = target.title
        case let .workspace(_, _, workspaceID):
            guard let target = session.groups.first(where: { $0.id == workspaceID }) else { return nil }
            agent = nil
            group = target
            title = target.name
        case .session:
            agent = nil
            group = nil
            title = session.name
        case .coreTerminal:
            return nil
        }
        return ResolvedNavigationDestination(
            destination: self,
            source: source.descriptor,
            session: session,
            agent: agent,
            group: group,
            isAvailable: source.online && session.online,
            title: title,
            subtitle: ([source.descriptor.name, session.name] + [group?.name].compactMap { $0 }).joined(separator: " / ")
        )
    }
}

struct ResolvedNavigationDestination: Sendable {
    let destination: NavigationDestination
    let source: SourceDescriptor
    let session: SessionInfo?
    let agent: AgentInfo?
    let group: AgentGroup?
    let isAvailable: Bool
    let title: String
    let subtitle: String
    var coreTerminal: CoreTerminalInfo? = nil
}

struct NavigationAttempt: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case pending
        case failed
        case succeeded
    }

    let destination: NavigationDestination
    let title: String
    let subtitle: String
    var phase: Phase
    var message: String?
}
