import AppKit
import Testing
@testable import Herdling

/// Fixture data for the render and layout harnesses: one local source with three spaces, a mix of
/// statuses, and an SSH source that fails, so every row kind the roster can draw is covered.
enum PreviewFixtures {
    @MainActor
    static func makeStore(defaults: UserDefaults = renderDefaults()) -> SessionStore {
        let statuses: [(String, AgentStatus, String)] = [
            ("genre-unit-validation", .working, "/repos/assessment"),
            ("π - Herdr Tab Direction", .idle, "/repos/assessment"),
            ("fix auth retry loop", .blocked, "/repos/assessment"),
            ("docs pass", .done, "/repos/assessment"),
            ("π - Pi Model Router", .working, "/tools"),
            ("π - Clash Verge TUN", .idle, "/tools"),
            ("π - Tingcast UI Redesign", .working, "/personal/projects/herdling"),
            ("README rewrite", .done, "/personal/projects/herdling"),
        ]
        let spaces: [(String, [String])] = [
            ("assessment", [
                "genre-unit-validation", "π - Herdr Tab Direction", "fix auth retry loop", "docs pass",
            ]),
            ("tools", ["π - Pi Model Router", "π - Clash Verge TUN"]),
            ("herdling", ["π - Tingcast UI Redesign", "README rewrite"]),
        ]
        let groups: [AgentGroup] = spaces.map { space, names in
            let agents = names.compactMap { name -> AgentInfo? in
                guard let entry = statuses.first(where: { $0.0 == name }) else { return nil }
                return AgentInfo(
                    paneID: "w1:\(name)",
                    title: name,
                    status: entry.1,
                    workspace: space,
                    cwd: entry.2,
                    updatedAt: .now
                )
            }
            return AgentGroup(id: "w-\(space)", name: space, agents: agents)
        }

        return SessionStore(
            client: HerdrClient(executable: nil),
            loadSource: { descriptor in
                if descriptor.sshAlias != nil {
                    throw HerdrClient.ClientError.failed("ssh: connect to host herdr.sock failed")
                }
                return [
                    HerdrClient.LoadedSession(name: "default", groups: groups, error: nil)
                ]
            },
            loadBranches: { _, paths in
                Dictionary(uniqueKeysWithValues: paths.map { ($0, "main") })
            },
            sourceDescriptors: [.local, .remote("kvm")],
            defaults: defaults
        )
    }

    /// A throwaway defaults suite: the harness must not read or write the user's own preferences,
    /// or the render would follow whatever the panel last had open.
    @MainActor
    static func renderDefaults() -> UserDefaults {
        let suite = "HerdlingRender.\(UUID())"
        return makeDefaults()
    }

    @MainActor
    private static func makeDefaults() -> UserDefaults {
        let suite = "HerdlingRender.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Could not create a temporary UserDefaults suite.")
        }
        defaults.set(true, forKey: "expanded.recent")
        defaults.set("", forKey: "expanded.source")
        return defaults
    }

    /// A store with its sessions loaded, for a harness that needs rows on screen.
    @MainActor
    static func loadedStore() async -> SessionStore {
        let store = makeStore()
        store.start()
        for _ in 0..<2_000 where store.sources.first?.sessions.isEmpty != false {
            await Task.yield()
        }
        return store
    }
}
