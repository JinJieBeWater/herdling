import Foundation

enum HerdrSocketMessage {
    case event(HerdrSocketEvent)
    case subscriptionStarted
    case other

    static func decode(_ data: Data) -> Self {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(EventEnvelope.self, from: data) {
            return .event(envelope.socketEvent)
        }
        if let acknowledgement = try? decoder.decode(AcknowledgementResponse.self, from: data),
           acknowledgement.id == "subscription",
           acknowledgement.result.type == "subscription_started"
        {
            return .subscriptionStarted
        }
        return .other
    }
}

enum HerdrSocketEvent {
    case agentStatusChanged(EventData)
    case paneUpdated(EventData)
    case paneClosed(paneID: String, workspaceID: String?)
    case tabClosed(tabID: String, workspaceID: String?)
    case resyncRequired
}

struct EventData: Decodable {
    let agent: String?
    let agentStatus: String?
    let cwd: String?
    let displayAgent: String?
    let foregroundCWD: String?
    let label: String?
    let paneID: String?
    let revision: UInt64?
    let tabID: String?
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let title: String?
    let workspaceID: String?

    enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case cwd
        case displayAgent = "display_agent"
        case foregroundCWD = "foreground_cwd"
        case label
        case paneID = "pane_id"
        case revision
        case tabID = "tab_id"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case title
        case workspaceID = "workspace_id"
    }
}

private struct EventEnvelopeData: Decodable {
    let direct: EventData
    let pane: EventData?

    private enum CodingKeys: String, CodingKey {
        case pane
    }

    init(from decoder: Decoder) throws {
        direct = try EventData(from: decoder)
        pane = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(EventData.self, forKey: .pane)
    }
}

private struct EventEnvelope: Decodable {
    let event: String
    let data: EventEnvelopeData

    var socketEvent: HerdrSocketEvent {
        switch event {
        case "pane.agent_status_changed", "pane_agent_status_changed":
            .agentStatusChanged(data.direct)
        case "pane.updated", "pane_updated":
            .paneUpdated(data.pane ?? data.direct)
        case "pane.closed", "pane_closed":
            data.direct.paneID.map { .paneClosed(paneID: $0, workspaceID: data.direct.workspaceID) }
                ?? .resyncRequired
        case "tab.closed", "tab_closed":
            data.direct.tabID.map { .tabClosed(tabID: $0, workspaceID: data.direct.workspaceID) }
                ?? .resyncRequired
        default:
            .resyncRequired
        }
    }
}

private struct AcknowledgementResponse: Decodable {
    struct Result: Decodable {
        let type: String
    }

    let id: String
    let result: Result
}
