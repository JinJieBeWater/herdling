import Foundation

enum HerdrSocketMessage {
    case snapshot([AgentGroup])
    case event
    case subscriptionStarted
    case other

    var isEvent: Bool {
        if case .event = self { true } else { false }
    }

    static func decode(_ data: Data, refreshedAt: Date) throws -> Self {
        let decoder = JSONDecoder()
        if try decoder.decode(EventProbe.self, from: data).event != nil { return .event }
        if let acknowledgement = try? decoder.decode(AcknowledgementResponse.self, from: data),
           acknowledgement.id == "subscription",
           acknowledgement.result.type == "subscription_started"
        {
            return .subscriptionStarted
        }
        guard let result = try? decoder.decode(SnapshotResponse.self, from: data).result,
              result.type == "session_snapshot"
        else { return .other }

        let workspaceNames = Dictionary(
            uniqueKeysWithValues: result.snapshot.workspaces.map { ($0.id, $0.label) }
        )
        var agentsByWorkspace: [String: [AgentInfo]] = [:]
        var unknownWorkspaceOrder: [String] = []
        for agent in result.snapshot.agents {
            if workspaceNames[agent.workspaceID] == nil, agentsByWorkspace[agent.workspaceID] == nil {
                unknownWorkspaceOrder.append(agent.workspaceID)
            }
            agentsByWorkspace[agent.workspaceID, default: []].append(AgentInfo(
                paneID: agent.paneID,
                title: agent.name
                    ?? agent.displayAgent
                    ?? agent.title
                    ?? agent.terminalTitleStripped
                    ?? agent.terminalTitle
                    ?? agent.agent
                    ?? agent.paneID,
                status: AgentStatus(rawValue: agent.status) ?? .unknown,
                workspace: workspaceNames[agent.workspaceID] ?? agent.workspaceID,
                cwd: agent.foregroundCWD ?? agent.cwd ?? "",
                updatedAt: refreshedAt
            ))
        }
        let known = result.snapshot.workspaces.map {
            AgentGroup(id: $0.id, name: $0.label, agents: agentsByWorkspace[$0.id] ?? [])
        }
        let unknown = unknownWorkspaceOrder.map {
            AgentGroup(id: $0, name: $0, agents: agentsByWorkspace[$0] ?? [])
        }
        return .snapshot(known + unknown)
    }
}

private struct EventProbe: Decodable {
    let event: String?
}

private struct AcknowledgementResponse: Decodable {
    struct Result: Decodable {
        let type: String
    }

    let id: String
    let result: Result
}

private struct SnapshotResponse: Decodable {
    struct Result: Decodable {
        struct Snapshot: Decodable {
            struct Workspace: Decodable {
                let id: String
                let label: String

                enum CodingKeys: String, CodingKey {
                    case id = "workspace_id"
                    case label
                }
            }

            struct Agent: Decodable {
                let agent: String?
                let displayAgent: String?
                let status: String
                let cwd: String?
                let foregroundCWD: String?
                let name: String?
                let paneID: String
                let terminalTitle: String?
                let terminalTitleStripped: String?
                let title: String?
                let workspaceID: String

                enum CodingKeys: String, CodingKey {
                    case agent
                    case displayAgent = "display_agent"
                    case status = "agent_status"
                    case cwd
                    case foregroundCWD = "foreground_cwd"
                    case name
                    case paneID = "pane_id"
                    case terminalTitle = "terminal_title"
                    case terminalTitleStripped = "terminal_title_stripped"
                    case title
                    case workspaceID = "workspace_id"
                }
            }

            let workspaces: [Workspace]
            let agents: [Agent]
        }

        let type: String
        let snapshot: Snapshot
    }

    let result: Result
}
