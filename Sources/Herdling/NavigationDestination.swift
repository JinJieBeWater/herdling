import Foundation

enum NavigationDestination: Hashable, Sendable {
    case agent(sourceID: String, sessionName: String, paneID: String)
    case workspace(sourceID: String, sessionName: String, workspaceID: String)
    case session(sourceID: String, sessionName: String)

    var sourceID: String {
        switch self {
        case let .agent(sourceID, _, _), let .workspace(sourceID, _, _), let .session(sourceID, _):
            sourceID
        }
    }

    var sessionName: String {
        switch self {
        case let .agent(_, sessionName, _), let .workspace(_, sessionName, _), let .session(_, sessionName):
            sessionName
        }
    }

    func resolve(in sources: [SourceInfo]) -> ResolvedNavigationDestination? {
        guard let source = sources.first(where: { $0.id == sourceID }),
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
    let session: SessionInfo
    let agent: AgentInfo?
    let group: AgentGroup?
    let isAvailable: Bool
    let title: String
    let subtitle: String
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
