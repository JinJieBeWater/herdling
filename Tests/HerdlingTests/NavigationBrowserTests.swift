import AppKit
import Foundation
import Testing
@testable import Herdling

@Suite @MainActor
struct NavigationBrowserTests {
    @Test func pointerHandoffIgnoresStationaryLayoutAndKeepsExactIdentityAcrossUpdates() {
        let sources = [source(.local, agents: [agent("same", .blocked, time: 1)]),
                       source(.remote("kvm"), agents: [agent("same", .working, time: 2)])]
        let browser = NavigationBrowser()
        let local = NavigationRowID.destination(target("same"))
        let remote = NavigationRowID.destination(target("same", source: "ssh:kvm"))
        browser.open(sources: sources, attempt: nil, keyboard: true, expandedSourceID: nil)
        let stationary = CGPoint(x: 10, y: 10), moved = CGPoint(x: 11, y: 10)
        browser.holdPointer(at: stationary)
        browser.selectFromPointer(remote, at: stationary)
        #expect(browser.highlightedSelection == local)
        #expect(!browser.allowsPointerHighlight, "Stationary header and command hover must yield to a keyboard row")
        browser.selectFromPointer(remote, at: moved)
        #expect(browser.highlightedSelection == remote)
        #expect(browser.keyboardSelection == nil)
        #expect(browser.allowsPointerHighlight)
        browser.pointerExited(local)
        #expect(browser.highlightedSelection == remote, "An old row's exit must not clear the new target")
        browser.holdPointer(at: moved)
        browser.moveSelection(by: -1)
        #expect(browser.highlightedSelection == local)
        browser.receive(sources: sources.reversed(), attempt: nil)
        browser.selectFromPointer(remote, at: moved)
        #expect(browser.highlightedSelection == local, "A refresh below a stationary pointer cannot steal keyboard ownership")
        #expect(browser.quickIDs.first == target("same"))
        browser.selectFromPointer(remote, at: CGPoint(x: 12, y: 10))
        #expect(browser.highlightedSelection == remote)
        browser.pointerExited(remote)
        #expect(browser.highlightedSelection == nil)
        #expect(browser.selection == remote, "Leaving a row keeps its exact identity for subsequent keyboard input")
        #expect(browser.attempt == nil)
    }

    @Test func pointerCannotActivateUnavailableAndClosedRows() {
        let sources = [source(.local, agents: [agent("a", .blocked, time: 1), agent("b", .working, time: 2)])]
        let browser = NavigationBrowser()
        let a = NavigationRowID.destination(target("a")), b = NavigationRowID.destination(target("b"))
        browser.open(sources: sources, attempt: nil, keyboard: true, expandedSourceID: nil)
        browser.holdPointer(at: CGPoint(x: 2, y: 0))
        browser.selectFromPointer(b, at: CGPoint(x: 2, y: 0))
        #expect(browser.selection == a, "A stationary pointer does not take keyboard ownership")
        browser.selectFromPointer(b, at: CGPoint(x: 3, y: 0))
        #expect(browser.highlightedSelection == b)
        browser.receive(sources: [], attempt: nil)
        browser.selectFromPointer(a, at: CGPoint(x: 4, y: 0))
        #expect(browser.highlightedSelection == nil)
        #expect(browser.activateSelection() == nil, "An unavailable row must not activate the previous pointer target")
        browser.open(sources: sources, attempt: nil, keyboard: false, expandedSourceID: nil)
        browser.setMode(.all)
        browser.selectFromPointer(.source("local"), at: CGPoint(x: 5, y: 0))
        #expect(browser.activateSelection() == nil)
        #expect(browser.expandedSourceID == "local", "Source hover changes selection, Enter only folds it")
        browser.selectFromPointer(nil, at: CGPoint(x: 6, y: 0))
        #expect(browser.selection == nil, "Moving into the header releases the roster target")
        browser.close()
        browser.selectFromPointer(a, at: CGPoint(x: 7, y: 0))
        #expect(browser.highlightedSelection == nil)
        #expect(browser.selection == nil)
    }

    private func target(_ pane: String, source: String = "local") -> NavigationDestination {
        .agent(sourceID: source, sessionName: "default", paneID: pane)
    }

    private func agent(_ pane: String, _ status: AgentStatus, time: Double) -> AgentInfo {
        AgentInfo(paneID: pane, title: "same-name", status: status, workspace: "project", cwd: "/tmp/project", updatedAt: Date(timeIntervalSince1970: time))
    }

    private func source(_ descriptor: SourceDescriptor, agents: [AgentInfo], online: Bool = true) -> SourceInfo {
        SourceInfo(descriptor: descriptor, sessions: [SessionInfo(name: "default", groups: [AgentGroup(id: "workspace", name: "project", agents: agents)], online: online)], online: online, error: nil)
    }

    @Test func openRanksAttentionBeforeWorkingAndUnvisitedIdleWithoutNavigation() {
        let sources = [
            source(.local, agents: [agent("working", .working, time: 50), agent("shared", .done, time: 30), agent("blocked", .blocked, time: 10)]),
            source(.remote("kvm"), agents: [agent("shared", .done, time: 20), agent("idle", .idle, time: 40)]),
        ]
        let browser = NavigationBrowser()
        browser.open(sources: sources, attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("blocked"), target("shared"), target("shared", source: "ssh:kvm"), target("working"), target("idle", source: "ssh:kvm")])
        #expect(browser.selection == nil)
        #expect(browser.activateSelection() == nil)
        #expect(browser.quickCandidateCount == 5)
    }

    @Test func liveUpdatesDoNotMoveRowsAndReopeningRebuildsTheSnapshot() {
        let old = agent("old", .done, time: 10)
        let browser = NavigationBrowser()
        browser.open(sources: [source(.local, agents: [old])], attempt: nil, keyboard: true, expandedSourceID: nil)
        #expect(browser.selection == .destination(target("old")))
        let added = agent("new", .blocked, time: 20)
        browser.receive(sources: [source(.local, agents: [added, old])], attempt: nil)
        #expect(browser.quickIDs == [target("old")])
        #expect(browser.quickCandidateCount == 2)
        browser.close()
        browser.open(sources: [source(.local, agents: [added, old])], attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("new"), target("old")])
        #expect(browser.selection == nil)

        browser.receive(sources: [source(.local, agents: [added, agent("old", .idle, time: 30)])], attempt: nil)
        #expect(browser.presentation(for: target("old")).status == .idle)
        #expect(browser.quickIDs == [target("new"), target("old")])
        browser.close()
        browser.open(sources: [source(.local, agents: [added, agent("old", .idle, time: 30)])], attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("new"), target("old")])
        browser.moveSelection(by: 1)
        browser.moveSelection(by: 1)
        #expect(browser.selection == .destination(target("old")))
        #expect(browser.activateSelection() == target("old"))

        browser.receive(sources: [source(.local, agents: [added, old], online: false)], attempt: nil)
        #expect(!browser.presentation(for: target("old")).available)
        #expect(browser.activateSelection() == nil)
    }

    @Test func recentIdleIsLimitedAcrossSourcesByStateTimeWithStableTies() {
        var local = source(.local, agents: [
            agent("old-idle", .idle, time: 1), agent("working", .working, time: 200),
            agent("tie-first", .idle, time: 90), agent("blocked", .blocked, time: 10),
            agent("tie-second", .idle, time: 90), agent("older-idle", .idle, time: 70),
            agent("done", .done, time: 20), agent("unknown", .unknown, time: 1_000),
        ])
        local.sessions.append(SessionInfo(name: "offline-session", agents: [
            agent("offline-session-idle", .idle, time: 1_000), agent("offline-session-blocked", .blocked, time: 1_000),
        ], online: false))
        let sources = [local,
            source(.remote("kvm"), agents: [agent("newest-idle", .idle, time: 100), agent("remote-older", .idle, time: 80)]),
            source(.remote("offline"), agents: [agent("offline-source-idle", .idle, time: 1_000)], online: false),
        ]
        let browser = NavigationBrowser()
        browser.open(sources: sources, attempt: nil, keyboard: true, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("blocked"), target("done"), target("working"),
            target("newest-idle", source: "ssh:kvm"), target("tie-first"), target("tie-second")])
        #expect(browser.quickCandidateCount == 6)
        #expect(browser.selection == .destination(target("blocked")))
        for _ in 0..<5 { browser.moveSelection(by: 1) }
        #expect(browser.activateSelection() == target("tie-second"), "Keyboard order must match priority rows exactly")
    }

    @Test func sourceAccordionAllowsAllToCollapseThroughMouseAndKeyboard() {
        let sources = [source(.local, agents: [agent("a", .done, time: 10)]),
                       source(.remote("kvm"), agents: [agent("b", .working, time: 20)])]
        let browser = NavigationBrowser(sources: sources)
        browser.setMode(.all)
        #expect(browser.expandedSourceID == nil)
        browser.toggleSource("local")
        #expect(browser.expandedSourceID == "local")
        browser.toggleSource("local")
        #expect(browser.expandedSourceID == nil)
        browser.toggleSource("local")
        browser.toggleSource("ssh:kvm")
        #expect(browser.expandedSourceID == "ssh:kvm")
        browser.toggleSource("ssh:kvm")
        #expect(browser.expandedSourceID == nil)
        browser.toggleSource("ssh:kvm")
        browser.toggleSource("missing")
        #expect(browser.expandedSourceID == "ssh:kvm")
        browser.moveSelection(by: 1)
        #expect(browser.selection == .source("local"))
        browser.horizontal(-1)
        #expect(browser.expandedSourceID == "ssh:kvm")
        browser.horizontal(1)
        #expect(browser.expandedSourceID == "local")
        #expect(browser.activateSelection() == nil)
        #expect(browser.expandedSourceID == nil)
        browser.horizontal(1)
        #expect(browser.expandedSourceID == "local")
        browser.horizontal(-1)
        #expect(browser.expandedSourceID == nil)
        browser.open(sources: sources, attempt: nil, keyboard: false, expandedSourceID: "ssh:kvm")
        #expect(browser.expandedSourceID == "ssh:kvm")
        browser.open(sources: [], attempt: nil, keyboard: false, expandedSourceID: "ssh:kvm")
        #expect(browser.expandedSourceID == nil)
    }

    @Test func directoryKeepsTopologyLiveStatesAndSeparateFoldingActions() {
        let browser = NavigationBrowser()
        browser.open(sources: [source(.local, agents: [agent("a", .done, time: 10)])], attempt: nil, keyboard: false, expandedSourceID: nil)
        browser.setMode(.all)
        browser.moveSelection(by: 1)
        #expect(browser.selection == .source("local"))
        #expect(browser.activateSelection() == nil)
        #expect(browser.expandedSourceID == "local")
        browser.moveSelection(by: 1)
        let workspace = NavigationDestination.workspace(sourceID: "local", sessionName: "default", workspaceID: "workspace")
        #expect(browser.selection == .destination(workspace))
        #expect(browser.activateSelection() == workspace)
        browser.moveSelection(by: 1)
        #expect(browser.selection == .destination(target("a")))
        browser.horizontal(-1)
        #expect(browser.selection == .destination(workspace))
        browser.horizontal(-1)
        #expect(browser.selection == .source("local"))
        browser.horizontal(-1)
        #expect(browser.expandedSourceID == nil)

        browser.receive(sources: [source(.local, agents: [agent("a", .working, time: 20), agent("b", .done, time: 30)])], attempt: nil)
        #expect(browser.allSources.first?.sessions.first?.agents.map(\.paneID) == ["a"])
        #expect(browser.allSources.first?.sessions.first?.agents.first?.status == .working)
        browser.receive(sources: [source(.local, agents: [])], attempt: nil)
        #expect(browser.allSources.first?.sessions.first?.agents.map(\.paneID) == ["a"])
        #expect(browser.allSources.first?.sessions.first?.agents.first?.status == .unknown)
        #expect(!browser.isAvailable(target("a")))
        browser.close()
        browser.open(sources: [source(.local, agents: [])], attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.allSources.first?.sessions.first?.agents.isEmpty == true)
        #expect(browser.selection == nil)
    }

    @Test func idleRecencyAndStatusChangesWaitForReopeningWithoutMovingSelection() {
        let initial = [source(.local, agents: [agent("a", .idle, time: 40), agent("b", .idle, time: 30),
            agent("c", .idle, time: 20), agent("d", .idle, time: 10)])]
        let browser = NavigationBrowser()
        browser.open(sources: initial, attempt: nil, keyboard: true, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("a"), target("b"), target("c")])
        let live = [source(.local, agents: [agent("a", .working, time: 1), agent("b", .idle, time: 30),
            agent("c", .idle, time: 20), agent("d", .idle, time: 50), agent("new", .blocked, time: 5)])]
        browser.receive(sources: live, attempt: nil)
        #expect(browser.quickIDs == [target("a"), target("b"), target("c")])
        #expect(browser.presentation(for: target("a")).status == .working)
        #expect(browser.activateSelection() == target("a"))
        browser.close()
        browser.open(sources: live, attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("new"), target("a"), target("d"), target("b"), target("c")])
        #expect(browser.selection == nil)
    }

    @Test func conciseLabelsKeepRemoteNamedSessionAndDuplicatePaneIdentity() {
        let namedAgent = agent("named", .done, time: 1)
        let named = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "dev", groups: [AgentGroup(id: "workspace", name: "project", agents: [namedAgent])], online: true)], online: true, error: nil)
        let browser = NavigationBrowser(sources: [source(.local, agents: [agent("one", .done, time: 1)]), source(.remote("kvm"), agents: [agent("one", .done, time: 1)])])
        #expect(browser.presentation(for: target("one")).subtitle == "project")
        #expect(browser.presentation(for: target("one", source: "ssh:kvm")).subtitle == "kvm / project")
        browser.open(sources: [named], attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.presentation(for: .agent(sourceID: "local", sessionName: "dev", paneID: "named")).subtitle == "dev / project")
        browser.open(sources: [source(.local, agents: [agent("one", .done, time: 1), agent("two", .done, time: 1)])], attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(browser.presentation(for: target("one")).subtitle == "project / one")
        #expect(browser.presentation(for: target("two")).subtitle == "project / two")
    }

    @Test func failedTargetSurvivesStatusChangeReopenAndDisappearance() {
        let browser = NavigationBrowser()
        let failure = NavigationAttempt(destination: target("original"), title: "Original agent", subtitle: "local / default / project", phase: .failed, message: "Activation failed")
        let idle = source(.local, agents: [agent("original", .idle, time: 20)])
        browser.open(sources: [idle], attempt: failure, keyboard: true, expandedSourceID: nil)
        #expect(browser.quickIDs == [target("original")])
        #expect(browser.recoveryTarget == nil, "An eligible idle target keeps failure feedback in its regular row")
        #expect(browser.activateSelection() == target("original"))
        browser.close()
        browser.open(sources: [source(.local, agents: [])], attempt: failure, keyboard: true, expandedSourceID: nil)
        #expect(browser.recoveryTarget == target("original"))
        #expect(browser.presentation(for: target("original")).title == "Original agent")
        #expect(!browser.presentation(for: target("original")).available)
        #expect(browser.activateSelection() == nil)
    }

    @Test func keyboardRequiresExplicitActivationAndYieldsToNativeTabAndShortcuts() {
        let browser = NavigationBrowser()
        browser.open(sources: [source(.local, agents: [agent("one", .done, time: 10)])], attempt: nil, keyboard: false, expandedSourceID: nil)
        #expect(PanelKeyboard.handle(36, browser: browser) == .passThrough)
        #expect(PanelKeyboard.handle(125, browser: browser) == .handled) // Down selects, never navigates.
        #expect(browser.selection == .destination(target("one")))
        #expect(PanelKeyboard.handle(36, browser: browser) == .navigate(target("one")))
        #expect(PanelKeyboard.handle(36, modifiers: .command, browser: browser) == .passThrough)
        #expect(PanelKeyboard.handle(48, modifiers: .shift, browser: browser) == .passThrough) // Shift-Tab returns native focus.
        #expect(browser.selection == nil)
        #expect(PanelKeyboard.handle(53, browser: browser) == .close)
        browser.setMode(.all)
        #expect(PanelKeyboard.handle(125, browser: browser) == .handled)
        #expect(PanelKeyboard.handle(36, browser: browser) == .handled) // Source Enter folds only, never navigates.
        #expect(browser.expandedSourceID == "local")
    }

    @Test func replacingRecoveryCannotActivateAnInvisibleSelection() {
        let sources = [source(.local, agents: [agent("a", .unknown, time: 10), agent("b", .done, time: 20)])]
        let browser = NavigationBrowser()
        let failure = NavigationAttempt(destination: target("a"), title: "A", subtitle: "local", phase: .failed, message: "Failed")
        browser.open(sources: sources, attempt: failure, keyboard: true, expandedSourceID: nil)
        browser.moveSelection(by: 1)
        #expect(browser.selection == .destination(target("a")))
        browser.receive(sources: sources, attempt: NavigationAttempt(destination: target("b"), title: "B", subtitle: "local", phase: .pending, message: nil))
        #expect(browser.recoveryTarget == nil)
        #expect(browser.selection == nil)
        #expect(browser.activateSelection() == nil)
    }
}
