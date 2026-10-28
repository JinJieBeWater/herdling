import Foundation
@testable import Herdling

enum PreviewFixtures {
    @MainActor
    static func makeStore(defaults: UserDefaults = renderDefaults()) -> SessionStore {
        SessionStore(
            client: HerdrClient(executable: nil),
            loadTerminalStatus: { _ in "Ready" },
            loadSource: { _ in [] },
            loadBranches: { _, _ in [:] },
            sourceDescriptors: [.local],
            defaults: defaults
        )
    }

    static func renderDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "HerdlingTests.\(UUID())") else {
            preconditionFailure("Could not create isolated test preferences")
        }
        return defaults
    }
}
