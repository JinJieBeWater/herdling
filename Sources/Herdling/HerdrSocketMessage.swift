import Foundation

enum HerdrSocketMessage {
    case snapshot([AgentGroup])
    case event
    case subscriptionStarted
    case other

    static func decode(_ data: Data, refreshedAt: Date) throws -> Self {
        let decoder = JSONDecoder()
        if try decoder.decode(EventProbe.self, from: data).event != nil { return .event }
        if let acknowledgement = try? decoder.decode(AcknowledgementResponse.self, from: data),
           acknowledgement.id == "subscription",
           acknowledgement.result.type == "subscription_started"
        {
            return .subscriptionStarted
        }
        guard let result = try? decoder.decode(ResponseTypeProbe.self, from: data).result,
              result.type == "session_snapshot"
        else { return .other }
        return .snapshot(try HerdrClient.parseGroups(data, refreshedAt: refreshedAt))
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

private struct ResponseTypeProbe: Decodable {
    struct Result: Decodable {
        let type: String
    }

    let result: Result
}
