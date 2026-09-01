import AppKit
import Foundation
import Testing
@testable import Herdling

@Suite
struct CoreBehaviorTests {
    @Test
    func localSourceUsesNativeUserDisplayNameWithFallbacks() {
        #expect(SourceDescriptor.localDisplayName(
            fullName: " JinJieBeWater ",
            username: "jinjiebewater"
        ) == "JinJieBeWater")
        #expect(SourceDescriptor.localDisplayName(fullName: "", username: "jinjiebewater") == "jinjiebewater")
        #expect(SourceDescriptor.localDisplayName(fullName: "", username: "") == "Local")
    }

    @Test
    func herdrParsingAndMenuPriority() throws {
        let sessions = Data(#"{"sessions":[{"name":"default","running":true},{"name":"old","running":false}]}"#.utf8)
        #expect(try HerdrClient.parseSessions(sessions) == ["default"])

        let snapshot = Data(#"{"result":{"snapshot":{"agents":[{"agent":"pi","agent_status":"blocked","cwd":"/tmp/repo","foreground_cwd":"/tmp/repo","name":"fix auth","pane_id":"w1:p1","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w1"}],"workspaces":[{"label":"repo","workspace_id":"w1"}]}}}"#.utf8)
        let agents = try HerdrClient.parseGroups(snapshot).flatMap(\.agents)
        #expect(agents.count == 1)
        #expect(agents[0].title == "fix auth")
        #expect(agents[0].workspace == "repo")

        let source = SourceInfo(
            descriptor: .local,
            sessions: [SessionInfo(name: "default", agents: agents, online: true)],
            online: true
        )
        #expect(MenuStatus.summarize([source]) == MenuStatus(
            counts: [AgentStatusCount(status: .blocked, count: 1)],
            availability: .online
        ))
        #expect(HerdrClient.shellQuote("a'b") == "'a'\\''b'")
        #expect(GhosttyController.appleScriptString("a\\\"b") == "\"a\\\\\\\"b\"")
        #expect(try HerdrClient(executable: "/opt/homebrew/bin/herdr").attachCommand(session: "default").hasPrefix("exec /usr/bin/env "))
    }

    @Test
    func remoteHerdrUsesLoginShellPath() {
        let command = HerdrClient.remoteCommand(arguments: ["session", "list", "--json"])
        #expect(command.hasPrefix("$SHELL -lc "))
        #expect(command.contains("herdr"))
    }

    @Test
    func herdrGroupedOrderIsPreserved() throws {
        let snapshot = Data(#"{"result":{"snapshot":{"agents":[{"agent":"pi","agent_status":"idle","cwd":"/w1/a","foreground_cwd":null,"name":"first-w1","pane_id":"w1:p1","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w1"},{"agent":"pi","agent_status":"blocked","cwd":"/w2/a","foreground_cwd":null,"name":"first-w2","pane_id":"w2:p1","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w2"},{"agent":"pi","agent_status":"done","cwd":"/w1/b","foreground_cwd":null,"name":"second-w1","pane_id":"w1:p2","terminal_title":null,"terminal_title_stripped":null,"workspace_id":"w1"}],"workspaces":[{"label":"Workspace 2","workspace_id":"w2"},{"label":"Workspace 1","workspace_id":"w1"},{"label":"Empty","workspace_id":"w3"}]}}}"#.utf8)

        let groups = try HerdrClient.parseGroups(snapshot)
        #expect(groups.map(\.name) == ["Workspace 2", "Workspace 1", "Empty"])
        #expect(groups[0].agents.map(\.title) == ["first-w2"])
        #expect(groups[1].agents.map(\.title) == ["first-w1", "second-w1"])
        #expect(groups[2].agents.isEmpty)
    }

    @Test
    func rosterNestsWorktreesUnderExistingSpaceWithoutReordering() {
        let groups = [
            AgentGroup(id: "my", name: "my", agents: []),
            AgentGroup(id: "engineer", name: "Engineer", agents: []),
            AgentGroup(id: "engineer-wt", name: "Engineer/investigate-inft-50", agents: []),
            AgentGroup(id: "v5", name: "v5", agents: []),
            AgentGroup(id: "v5-wt", name: "v5/leap-309", agents: []),
            AgentGroup(id: "standalone", name: "unknown/path", agents: [])
        ]

        let spaces = RosterLayout.spaces(from: groups)
        #expect(spaces.map(\.name) == ["my", "Engineer", "v5", "unknown/path"])
        #expect(spaces[1].worktrees.map(\.name) == ["Engineer/investigate-inft-50"])
        #expect(spaces[1].groups.map(\.name) == ["Engineer", "Engineer/investigate-inft-50"])
        #expect(spaces[1].worktreeName(spaces[1].worktrees[0]) == "investigate-inft-50")
        #expect(spaces[1].displayedWorktrees.map(\.name) == ["investigate-inft-50"])
        #expect(spaces[1].displayedWorktrees.map(\.group.name) == ["Engineer/investigate-inft-50"])
        #expect(spaces[2].worktrees.map(\.name) == ["v5/leap-309"])

        let primaryAgent = AgentInfo(
            paneID: "pane", title: "agent", status: .idle, workspace: "Engineer",
            cwd: "/repo", updatedAt: .now
        )
        let populated = RosterSpace(
            primary: AgentGroup(id: "engineer", name: "Engineer", agents: [primaryAgent]),
            worktrees: [groups[2]]
        )
        #expect(populated.displayedWorktrees.map(\.name) == [
            "Main",
            "investigate-inft-50",
        ])

        let nestedBranch = RosterLayout.spaces(from: [
            AgentGroup(id: "a", name: "A", agents: []),
            AgentGroup(id: "branch", name: "A/feature/nested", agents: [])
        ])
        #expect(nestedBranch.map(\.name) == ["A"])
        #expect(nestedBranch[0].worktreeName(nestedBranch[0].worktrees[0]) == "feature/nested")
    }

    @Test
    func rosterStorageKeysCannotCollide() {
        let first = RosterLayout.storageKey("branches", components: ["ssh:a", "b.c", "w"])
        let second = RosterLayout.storageKey("branches", components: ["ssh:a.b", "c", "w"])
        #expect(first != second)
    }

    @Test
    func singleDefaultSessionHeaderIsHidden() {
        #expect(!RosterLayout.showsSessionHeader(name: "default", sourceSessionCount: 1))
        #expect(RosterLayout.showsSessionHeader(name: "default", sourceSessionCount: 2))
        #expect(RosterLayout.showsSessionHeader(name: "work", sourceSessionCount: 1))
    }

    @Test
    func accordionAllowsAllSourcesToCollapse() {
        #expect(RosterLayout.expandedSourceID(saved: "ssh:kvm", available: ["local", "ssh:kvm"]) == "ssh:kvm")
        #expect(RosterLayout.expandedSourceID(saved: "missing", available: ["local", "ssh:kvm"]) == "local")
        #expect(RosterLayout.expandedSourceID(saved: "", available: ["local", "ssh:kvm"]) == nil)
        #expect(RosterLayout.expandedSourceID(saved: "local", available: []) == nil)
    }

    @Test
    func gitBranchOutputIgnoresNonRepositories() {
        let data = Data("/repo\tmain\n/tmp\t\n/worktree\tfeature/nested\n".utf8)
        #expect(GitBranchResolver.parse(data) == [
            "/repo": "main",
            "/worktree": "feature/nested",
        ])
    }

    @Test
    func branchPathsIncludeEveryUniqueAgentCWD() {
        let first = AgentInfo(
            paneID: "p1", title: "one", status: .idle, workspace: "Space",
            cwd: "/repo", updatedAt: .now
        )
        let second = AgentInfo(
            paneID: "p2", title: "two", status: .idle, workspace: "Space",
            cwd: "/repo-worktree", updatedAt: .now
        )
        let duplicate = AgentInfo(
            paneID: "p3", title: "three", status: .idle, workspace: "Space",
            cwd: "/repo", updatedAt: .now
        )
        let space = RosterSpace(
            primary: AgentGroup(id: "root", name: "Space", agents: [first, second, duplicate]),
            worktrees: []
        )

        #expect(RosterLayout.branchPaths(from: [space]) == ["/repo", "/repo-worktree"])
        #expect(RosterLayout.branchSummary(
            for: space.primary.agents,
            resolved: ["/repo-worktree": "feature/nested"]
        ) == .single("feature/nested"))
        #expect(RosterLayout.branchSummary(
            for: space.primary.agents,
            resolved: ["/repo": "main", "/repo-worktree": "feature/nested"]
        ) == .mixed)
    }

    @Test
    func sourceStatusCountsHideZerosAndKeepPriorityOrder() {
        func agent(_ id: String, _ status: AgentStatus) -> AgentInfo {
            AgentInfo(
                paneID: id,
                title: id,
                status: status,
                workspace: "space",
                cwd: "/repo",
                updatedAt: .now
            )
        }

        let counts = RosterLayout.statusCounts(agents: [
            agent("idle", .idle),
            agent("blocked-1", .blocked),
            agent("working", .working),
            agent("done", .done),
            agent("blocked-2", .blocked),
            agent("unknown", .unknown),
        ])

        #expect(counts == [
            AgentStatusCount(status: .blocked, count: 2),
            AgentStatusCount(status: .done, count: 1),
            AgentStatusCount(status: .working, count: 1),
            AgentStatusCount(status: .idle, count: 1),
            AgentStatusCount(status: .unknown, count: 1),
        ])
    }

    @Test
    func emptyGroupsAreNotFocusTargets() {
        let agent = AgentInfo(
            paneID: "pane",
            title: "agent",
            status: .idle,
            workspace: "Space",
            cwd: "/repo",
            updatedAt: .now
        )

        #expect(!RosterLayout.canFocusGroup(agents: [], sessionOnline: true))
        #expect(!RosterLayout.canFocusGroup(agents: [agent], sessionOnline: false))
        #expect(RosterLayout.canFocusGroup(agents: [agent], sessionOnline: true))
    }

    @Test
    func sourceBranchPathsBatchEverySessionOnce() {
        func agent(_ id: String, cwd: String, workspace: String) -> AgentInfo {
            AgentInfo(
                paneID: id,
                title: id,
                status: .idle,
                workspace: workspace,
                cwd: cwd,
                updatedAt: .now
            )
        }

        let sessions = [
            SessionInfo(
                name: "first",
                agents: [
                    agent("one", cwd: "/repo", workspace: "Space"),
                    agent("two", cwd: "/worktree", workspace: "Space/feature"),
                ],
                online: true
            ),
            SessionInfo(
                name: "second",
                agents: [
                    agent("duplicate", cwd: "/repo", workspace: "Other"),
                    agent("three", cwd: "/other", workspace: "Other"),
                ],
                online: true
            ),
        ]

        #expect(SessionStore.branchPaths(from: sessions) == ["/repo", "/worktree", "/other"])
    }

    @Test
    func gitBranchResolverCachesPositiveAndNegativeResults() async {
        let recorder = BranchQueryRecorder()
        let resolver = GitBranchResolver(cacheDuration: 15) { _, paths in
            recorder.resolve(paths)
        }

        let first = await resolver.branches(source: .local, paths: ["/repo", "/tmp"])
        let second = await resolver.branches(source: .local, paths: ["/repo", "/tmp"])
        #expect(first == ["/repo": "main"])
        #expect(second == first)
        #expect(recorder.callCount == 1)
    }

    @Test
    @MainActor
    func latestRequestSupersedesEarlierFocus() async {
        let gate = AsyncGate()
        var completed: [Int] = []
        let runner = LatestRequestRunner<Int> { value in
            completed.append(value)
            if value == 1 { await gate.wait() }
        }

        runner.submit(1)
        while completed.isEmpty { await Task.yield() }
        runner.submit(2)
        runner.submit(3)
        await gate.release()
        while runner.isRunning { await Task.yield() }

        #expect(completed == [1, 3])
    }

    @Test
    func ghosttyStorageKeysCannotCollideAcrossSourceAndSession() {
        let first = GhosttyController.mappingKey(source: .remote("a"), session: "b.c")
        let second = GhosttyController.mappingKey(source: .remote("a.b"), session: "c")
        #expect(first != second)
    }

    @Test
    func existingUnclaimedHerdrTerminalIsAdoptedOnlyWhenUnambiguous() {
        #expect(GhosttyController.adoptableTerminalID(
            liveTerminalIDs: ["local-terminal", "remote-terminal"],
            claimedTerminalIDs: ["remote-terminal"],
            allClientTTYs: ["ttys000", "ttys021"],
            targetTTYs: ["ttys000"]
        ) == "local-terminal")

        #expect(GhosttyController.adoptableTerminalID(
            liveTerminalIDs: ["shell", "local-terminal", "remote-terminal"],
            claimedTerminalIDs: ["remote-terminal"],
            allClientTTYs: ["ttys000", "ttys021"],
            targetTTYs: ["ttys000"]
        ) == nil)
    }

    @Test
    func ghosttyClientCatalogKeepsExactSourceAndSession() {
        let output = """
         100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
         110 100 ttys000 /usr/bin/login -flp user /bin/zsh
         111 110 ttys000 /opt/homebrew/bin/herdr --session default
         120 100 ttys021 /usr/bin/login -flp user /bin/zsh
         121 120 ttys021 /opt/homebrew/bin/herdr --remote kvm --session work
         130 1 ttys009 /opt/homebrew/bin/herdr --session default
        """

        #expect(GhosttyProcessCatalog.clients(from: output, ghosttyPID: 100) == [
            GhosttyClientProcess(tty: "ttys000", sourceID: "local", session: "default"),
            GhosttyClientProcess(tty: "ttys021", sourceID: "ssh:kvm", session: "work"),
        ])
    }

    @Test
    func sshConfigFollowsIncludesAndEqualsSyntax() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdling-ssh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        try "Include config.d/*\nHost=root\nHost=equals\nHost -danger *.wild !blocked\n"
            .write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host included\nInclude ../config\n"
            .write(to: root.appendingPathComponent("config.d/one"), atomically: true, encoding: .utf8)

        #expect(SSHConfig.aliases(at: root.appendingPathComponent("config")) == ["included", "root", "equals"])
    }

    @Test
    @MainActor
    func panelVisibilityReschedulesPolling() async {
        let recorder = SleepRecorder()
        let store = SessionStore(client: HerdrClient(executable: nil)) { duration in
            try await recorder.sleep(duration)
        }

        store.start()
        await recorder.waitForCount(1)
        let closedDurations = await recorder.durations
        #expect(closedDurations == [.seconds(15)])

        store.setPanelOpen(true)
        await recorder.waitForCount(2)
        let openDurations = await recorder.durations
        #expect(openDurations == [.seconds(15), .seconds(2)])

        await recorder.releaseFirstSleep()
        for _ in 0..<100 { await Task.yield() }
        #expect(await recorder.durations.count == 2)
        store.stop()
    }

    @Test
    @MainActor
    func initialSourceFailureRetriesBeforeShowingError() async {
        let loader = FlakySourceLoader()
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            loadSource: { try loader.load($0) }
        )

        store.start()
        for _ in 0..<1_000 where !store.sources[0].online { await Task.yield() }
        #expect(loader.callCount == 2)
        #expect(store.sources[0].online)
        #expect(store.sources[0].error == nil)
        store.stop()
    }

    @Test
    @MainActor
    func refreshPublishesSourceAndBranchesAtomically() async {
        let branchStarted = AsyncGate()
        let releaseBranch = AsyncGate()
        let agent = AgentInfo(
            paneID: "pane",
            title: "agent",
            status: .working,
            workspace: "Space",
            cwd: "/repo",
            updatedAt: .now
        )
        let store = SessionStore(
            client: HerdrClient(executable: nil),
            loadSource: { _ in
                [HerdrClient.LoadedSession(
                    name: "default",
                    groups: [AgentGroup(id: "space", name: "Space", agents: [agent])],
                    error: nil
                )]
            },
            loadBranches: { _, paths in
                await branchStarted.release()
                await releaseBranch.wait()
                return Dictionary(uniqueKeysWithValues: paths.map { ($0, "main") })
            }
        )
        var changes = 0
        store.onChange = { changes += 1 }

        let refresh = Task { await store.refresh() }
        await branchStarted.wait()
        #expect(store.sources[0].sessions.isEmpty)
        #expect(changes == 0)

        await releaseBranch.release()
        await refresh.value
        #expect(store.sources[0].sessions.first?.agents.map(\.paneID) == ["pane"])
        #expect(store.sources[0].branches == ["/repo": "main"])
        #expect(changes == 1)
    }

    @Test
    @MainActor
    func statusItemOwnsNativeLayoutAndAccessibility() {
        let status = MenuStatus(
            counts: [
                AgentStatusCount(status: .done, count: 1),
                AgentStatusCount(status: .working, count: 4),
                AgentStatusCount(status: .idle, count: 15),
            ],
            availability: .online
        )
        let presentation = MenuBarStatusPresentation.for(status)
        #expect(presentation.entries.map(\.statusSymbol) == [
            "checkmark.circle.fill",
            "circle.lefthalf.filled",
            "circle",
        ])
        #expect(presentation.entries.compactMap(\.count) == [1, 4, 15])
        #expect(presentation.accessibilityText == "Herdling, 1 completed agent, 4 working agents, 15 idle agents")
        #expect(MenuBarStatusPresentation.for(
            MenuStatus(counts: [], availability: .loading)
        ).entries.first?.statusSymbol == "ellipsis")
        #expect(MenuBarStatusPresentation.for(
            MenuStatus(counts: [], availability: .offline)
        ).entries.first?.statusSymbol == "wifi.slash")
        #expect(MenuBarStatusPresentation.for(
            MenuStatus(counts: [], availability: .online)
        ).entries.first?.statusSymbol == "circle.dotted")

        let statusItem = MenuBarStatusItem()
        defer { NSStatusBar.system.removeStatusItem(statusItem.item) }
        statusItem.update(status)
        #expect(statusItem.item.length > 50)
        #expect(statusItem.item.button?.accessibilityLabel() == presentation.accessibilityText)
        #expect(statusItem.item.button?.image?.isTemplate == true)
    }

    @Test
    func rosterWorkingColorUsesSystemAccent() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        var accent: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        #expect(StatusPalette.workingColor(for: appearance) == accent)
    }

    @Test
    func agentStatusIndicatorsStayDistinct() {
        #expect(AgentStatus.blocked.indicatorSymbolName == "xmark.circle.fill")
        #expect(AgentStatus.working.indicatorSymbolName == "circle.lefthalf.filled")
        #expect(AgentStatus.done.indicatorSymbolName == "checkmark.circle.fill")
        #expect(AgentStatus.idle.indicatorSymbolName == "circle")
        #expect(AgentStatus.unknown.indicatorSymbolName == "questionmark.circle")
    }

    @Test
    @MainActor
    func panelPlacementStaysInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        let buttonRect = NSRect(x: 980, y: 280, width: 20, height: 20)
        let panelSize = StatusItemController.panelSize(
            preferred: NSSize(width: 900, height: 340),
            buttonRect: buttonRect,
            visibleFrame: visibleFrame
        )
        let origin = StatusItemController.panelOrigin(
            buttonRect: buttonRect,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        #expect(panelSize == NSSize(width: 900, height: 256))
        #expect(origin == NSPoint(x: 92, y: 16))
        #expect(origin.y + panelSize.height <= visibleFrame.maxY)
        #expect(StatusItemController.availablePanelHeight(
            buttonRect: buttonRect,
            visibleFrame: visibleFrame
        ) == 256)

        let narrowPanel = StatusItemController.panelSize(
            preferred: NSSize(width: 900, height: 340),
            buttonRect: NSRect(x: 480, y: 780, width: 20, height: 20),
            visibleFrame: NSRect(x: 0, y: 0, width: 500, height: 800)
        )
        #expect(narrowPanel.width == 484)
        #expect(narrowPanel.width - 36 > 0)
    }

    @Test
    @MainActor
    func panelHeightTracksContentWithinBounds() {
        #expect(PanelHeightMeasurement(header: 39.5, body: 205.25).total == 244.75)
        #expect(StatusItemController.clampedContentHeight(20) == 100)
        #expect(StatusItemController.clampedContentHeight(245.2) == 246)
        #expect(StatusItemController.clampedContentHeight(900) == 900)

        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let buttonRect = NSRect(x: 900, y: 780, width: 20, height: 20)
        let fullHeightSize = StatusItemController.panelSize(
            preferred: NSSize(width: 420, height: 900),
            buttonRect: NSRect(x: 900, y: 800, width: 20, height: 20),
            visibleFrame: visibleFrame
        )
        #expect(fullHeightSize.height == 772)
        let compactSize = NSSize(width: 900, height: 200)
        let expandedSize = NSSize(width: 900, height: 500)
        let compactOrigin = StatusItemController.panelOrigin(
            buttonRect: buttonRect,
            panelSize: compactSize,
            visibleFrame: visibleFrame
        )
        let expandedOrigin = StatusItemController.panelOrigin(
            buttonRect: buttonRect,
            panelSize: expandedSize,
            visibleFrame: visibleFrame
        )
        #expect(compactOrigin.y + compactSize.height == expandedOrigin.y + expandedSize.height)
    }

    @Test
    @MainActor
    func visiblePanelResizeKeepsTopAndHorizontalAnchor() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let collapsed = NSRect(x: 1979, y: 1266, width: 420, height: 136)
        let expanded = StatusItemController.resizedVisiblePanelFrame(
            currentFrame: collapsed,
            preferredHeight: 1600,
            visibleFrame: visibleFrame
        )
        let collapsedAgain = StatusItemController.resizedVisiblePanelFrame(
            currentFrame: expanded,
            preferredHeight: 136,
            visibleFrame: visibleFrame
        )

        #expect(expanded.minX == collapsed.minX)
        #expect(expanded.maxY == collapsed.maxY)
        #expect(expanded.minY == visibleFrame.minY + StatusItemController.panelBottomMargin)
        #expect(collapsedAgain.minX == collapsed.minX)
        #expect(collapsedAgain.maxY == collapsed.maxY)
    }

    @Test
    @MainActor
    func rosterWidthDoesNotChangeWithCollapseState() {
        #expect(StatusItemController.panelWidth == 420)
    }

    @Test
    @MainActor
    func sourceSelectionImmediatelyNotifiesStatusItem() {
        let store = SessionStore(client: HerdrClient(executable: nil))
        var changes = 0
        store.onChange = { changes += 1 }
        store.setRemoteAlias("missing", enabled: false)
        #expect(changes == 1)
        store.stop()
    }

    @Test
    func statusButtonHitZoneIncludesScreenTop() {
        let frame = NSRect(x: 100, y: 775, width: 24, height: 20)
        #expect(PanelOutsideClickMonitor.pointHitsStatusButton(
            NSPoint(x: 112, y: 800),
            buttonFrame: frame,
            screenTop: 800
        ))
        #expect(!PanelOutsideClickMonitor.pointHitsStatusButton(
            NSPoint(x: 99, y: 800),
            buttonFrame: frame,
            screenTop: 800
        ))
    }

    @Test
    func panelEscapeReturnsFromSettingsBeforeClosing() {
        #expect(StatusItemController.escapeAction(showingSettings: true) == .showRoster)
        #expect(StatusItemController.escapeAction(showingSettings: false) == .closePanel)
    }
}

private actor SleepRecorder {
    private(set) var durations: [Duration] = []
    private var firstSleepReleased = false

    func sleep(_ duration: Duration) async throws {
        let index = durations.count
        durations.append(duration)
        if index == 0 {
            while !firstSleepReleased { await Task.yield() }
            return
        }
        try await Task.sleep(for: .seconds(30))
    }

    func releaseFirstSleep() {
        firstSleepReleased = true
    }

    func waitForCount(_ count: Int) async {
        while durations.count < count { await Task.yield() }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FlakySourceLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func load(_: SourceDescriptor) throws -> [HerdrClient.LoadedSession] {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { throw HerdrClient.ClientError.failed("herdr: command not found") }
        return []
    }
}

private final class BranchQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func resolve(_ paths: [String]) -> [String: String] {
        lock.withLock { calls += 1 }
        return paths.contains("/repo") ? ["/repo": "main"] : [:]
    }
}
