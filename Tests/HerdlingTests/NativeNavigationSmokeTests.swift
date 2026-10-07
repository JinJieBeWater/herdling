import Foundation
import Testing
@testable import Herdling

/// Opt-in only: point at panes created in a disposable herdling-navigation-check-* session.
struct NativeNavigationSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERDLING_SMOKE_SESSION"] != nil))
    func publicFocusReachesExactSameNamedPane() throws {
        let environment = ProcessInfo.processInfo.environment
        let session = try #require(environment["HERDLING_SMOKE_SESSION"])
        try #require(session.hasPrefix("herdling-navigation-check-"))
        let target = try #require(environment["HERDLING_SMOKE_TARGET"])
        let other = try #require(environment["HERDLING_SMOKE_OTHER"])
        try #require(target != other)
        let client = HerdrClient()
        let agents = try client.snapshotGroups(session: session).flatMap(\.agents)
        let requested = try #require(agents.first { $0.paneID == target })
        let namesake = try #require(agents.first { $0.paneID == other })
        #expect(requested.title == namesake.title)

        try client.focus(session: session, paneID: target)

        let data = try CommandRunner.run("/usr/bin/env", ["herdr", "--session", session, "api", "snapshot"])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let snapshot = try #require(result["snapshot"] as? [String: Any])
        #expect(snapshot["focused_pane_id"] as? String == target)
        #expect(snapshot["focused_tab_id"] as? String == requested.tabID)
        let updated = try client.snapshotGroups(session: session).flatMap(\.agents)
        #expect(updated.first { $0.paneID == target }?.status == .idle)
        print("Verified public pane.focus: \(session) / \(target), not same-named \(other)")
    }
}
