import AppKit
import SwiftUI
import Testing
import Vision
@testable import Herdling

@Suite(.serialized)
@MainActor
struct NavigationPanelTests {
    private let directory = URL(fileURLWithPath: "/tmp/herdling-navigation-render-\(UUID().uuidString)")

    @Test(arguments: [ColorScheme.light, .dark])
    func groupSummaryProtectsTheTitleAndShowsOnlyTheTwoHighestPriorityStates(scheme: ColorScheme) throws {
        let counts = [AgentStatus.blocked, .done, .working, .idle, .unknown].map { AgentStatusCount(status: $0, count: 2) }
        #expect(counts.statusCountsText == "2 needs you, 2 done, 2 working, 2 ready, 2 unknown",
                "The shared help/accessibility text keeps every count despite visual compaction")
        for branch in ["main", "feature/assessment-consulting"] {
            let row = GroupHeaderRow(
                leading: RowSymbol(symbol: "square.dashed", tint: nil), title: "assessment",
                subtitle: { GitBranchLabel(summary: .single(branch)) }, isExpanded: nil, indent: 12,
                accessibilityLabel: "assessment", accessibilityHint: "Opens this group", action: {}
            ) { GroupActivitySummary(counts: counts) }
            let image = try render(row.padding(.horizontal, Theme.Spacing.panelInset), height: 32,
                                   name: "compact-summary-\(scheme)-\(branch == "main" ? "short" : "long")", scheme: scheme)
            let visible = try text(in: image)
            #expect(visible.contains("assessment"), "The primary identity must not be squeezed by metadata: \(visible)")
            #expect(visible.contains("2 blocked") && visible.contains("2 done"), "Keep the most important counts: \(visible)")
            #expect(!visible.contains("working") && !visible.contains("idle") && !visible.contains("unknown"),
                    "Lower-priority counts belong in help and accessibility, not across the title")
            #expect(fittingHeight { row } == 32, "Compaction must not change row geometry")
        }
    }

    @Test func realPointerMovementTakesTheKeyboardTargetWithoutNavigating() throws {
        let store = PreviewFixtures.makeStore()
        let agents = ["first", "second"].map {
            AgentInfo(paneID: $0, title: $0, status: .working, workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        }
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: agents, online: true)], online: true)
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        let second = browser.quickIDs[1]
        let hosted = host(NavigationList(store: store, browser: browser).environment(\.navigationBrowser, browser), height: 100)
        defer { hosted.window.close() }
        try movePointer(in: hosted, to: NSPoint(x: 100, y: 62))
        #expect(browser.selection == .destination(second))
        #expect(browser.keyboardSelection == nil)
        let image = NSBitmapImageRep(cgImage: try snapshot(hosted.view, name: "pointer-handoff"))
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        let oldFill = try #require(image.colorAt(x: Int(300 * scale), y: Int(20 * scale)))
        let newFill = try #require(image.colorAt(x: Int(300 * scale), y: Int(62 * scale)))
        #expect(oldFill.alphaComponent < 0.01, "The old keyboard target loses its surface")
        #expect(newFill.alphaComponent > 0.9, "Only the new pointer target has the menu highlight")
        #expect(store.navigationAttempt == nil, "Hover must not submit a jump or seen")
        browser.receive(sources: [source], attempt: NavigationAttempt(destination: second, title: "second", subtitle: "fixture",
            phase: .failed, message: "Fixture failure"))
        _ = PanelKeyboard.handle(126, browser: browser)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosted.view.layoutSubtreeIfNeeded()
        try movePointer(in: hosted, to: NSPoint(x: 390, y: 62))
        #expect(browser.selection == .destination(second), "A nested Retry and its row share one exact pointer target")
        #expect(PanelKeyboard.handle(36, browser: browser) == .navigate(second), "Enter follows the visible pointer target")
    }

    @Test(arguments: [false, true])
    func movingIntoPanelCommandsReleasesTheRosterKeyboardTarget(header: Bool) throws {
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [
            AgentInfo(paneID: "fixture", title: "Fixture", status: .working, workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        ], online: true)], online: true)
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        let command = header ? AnyView(NavigationHeader(browser: browser)) : AnyView(RosterActionPill(title: "Retry", action: {}))
        let hosted = host(command
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.navigationBrowser, browser), height: 40)
        defer { hosted.window.close() }
        #expect(browser.keyboardSelection != nil)
        try movePointer(in: hosted, to: NSPoint(x: 20, y: 10))
        #expect(browser.keyboardSelection == nil)
        #expect(browser.selection == nil, "A command outside a roster row must not leave Enter on the previous target")
        #expect(browser.allowsPointerHighlight)
        #expect(browser.attempt == nil)
    }

    @Test
    func viewNamesDescribeTheirContentAndOfflineCountHasMeaning() throws {
        let online = SourceInfo(descriptor: .local, sessions: [], online: true)
        let offline = SourceInfo(descriptor: .remote("offline-host"), sessions: [], online: false, error: "Offline")
        let browser = NavigationBrowser(sources: [online, offline])
        let initial = try text(in: render(NavigationHeader(browser: browser), height: 38, name: "role-labels-one-offline"))
        #expect(initial.contains("Activity") && initial.contains("Sources"))
        #expect(initial.contains("1 offline"), "A bare number does not explain the connection indicator")
        #expect(!initial.contains("Need attention") && !initial.contains("All agents"))
        browser.receive(sources: [online, offline,
            SourceInfo(descriptor: .remote("another-host"), sessions: [], online: false, error: "Offline")], attempt: nil)
        let multiple = try text(in: render(NavigationHeader(browser: browser), height: 38, name: "role-labels-two-offline"))
        #expect(multiple.contains("2 offline"))
        browser.receive(sources: [online], attempt: nil)
        let connected = try text(in: render(NavigationHeader(browser: browser), height: 38, name: "role-labels-connected"))
        #expect(!connected.contains("offline"))
    }

    @Test(arguments: [2.0, 36.0])
    func viewChoicesKeepFullHitAreasWithoutPersistentBackgrounds(hitY: CGFloat) async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let browser = NavigationBrowser(sources: store.sources)
        let hosted = host(NavigationHeader(browser: browser), height: 38)
        defer { hosted.window.close() }
        func controls(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let controls = controls(in: hosted.view)
        #expect(controls.isEmpty, "The native gray control does not match the panel's bar-control language")
        let image = try snapshot(hosted.view, name: "connected-header")
        let bitmap = NSBitmapImageRep(cgImage: image)
        func alpha(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> CGFloat {
            let scale = CGFloat(bitmap.pixelsWide) / Theme.Size.panelWidth
            return try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))).alphaComponent
        }
        #expect(try (0..<200).allSatisfy { try alpha(bitmap, x: CGFloat($0), y: 7) < 0.01 },
                "Both view choices are transparent at rest, including the current one")
        #expect(try alpha(bitmap, x: 250, y: 19) < 0.01, "Header must not have a shared background")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 150, y: hitY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            hosted.window.sendEvent(event)
        }
        try await Task.sleep(for: .seconds(Theme.Duration.expand * 2))
        #expect(browser.mode == .all)
        #expect(store.navigationAttempt == nil)
        let selectedImage = try snapshot(hosted.view, name: "connected-header-selected")
        let selectedBitmap = NSBitmapImageRep(cgImage: selectedImage)
        #expect(try (0..<200).allSatisfy { try alpha(selectedBitmap, x: CGFloat($0), y: 7) < 0.01 },
                "Changing view does not leave a selected plate behind")
        let visible = try text(in: selectedImage)
        #expect(!visible.contains("Update list"))
        #expect(!visible.contains("Quick access"))
    }

    @Test
    func attentionRowsDoNotRepeatTheViewNameOrCount() throws {
        let store = PreviewFixtures.makeStore()
        let agents = [AgentStatus.blocked, .done].enumerated().map { index, status in
            AgentInfo(paneID: "caption-pane-\(index)", title: "Caption target \(index)", status: status,
                      workspace: "fixture", cwd: "/fixture", updatedAt: Date(timeIntervalSince1970: 0))
        }
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: agents, online: true)], online: true, error: nil)
        let browser = NavigationBrowser(sources: [source])
        let list = NavigationList(store: store, browser: browser).environment(\.navigationBrowser, browser)
        let visible = try text(in: render(list, height: 150, name: "attention-without-caption"))
        for agent in agents { #expect(visible.contains(agent.title)) }
        #expect(!visible.contains("Needs attention"))
        #expect(fittingHeight { list } == 82, "Two target rows and one 2pt gap, no 32pt caption")
        browser.moveSelection(by: 1)
        #expect(browser.activateSelection() == .agent(sourceID: "local", sessionName: "default", paneID: agents[0].paneID))
        #expect(store.navigationAttempt == nil)
    }

    @Test
    func workingRowOmitsDuplicateTextButKeepsRequestAndUnavailableFeedback() throws {
        let store = PreviewFixtures.makeStore()
        let agent = AgentInfo(paneID: "active", title: "Active target", status: .working,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)
        let browser = NavigationBrowser(sources: [source])
        let destination = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "active")
        let row = QuickNavigationRow(store: store, browser: browser, destination: destination).environment(\.navigationBrowser, browser)
        let normal = try text(in: render(row, height: 40, name: "working-no-duplicate"))
        #expect(normal.contains("Active target"))
        #expect(!normal.lowercased().contains("working"))
        #expect(browser.presentation(for: destination).status == .working)
        browser.receive(sources: [source], attempt: NavigationAttempt(destination: destination, title: agent.title, subtitle: "fixture", phase: .pending, message: nil))
        #expect(try text(in: render(row, height: 40, name: "working-opening")).contains("Opening"))
        browser.receive(sources: [source], attempt: NavigationAttempt(destination: destination, title: agent.title, subtitle: "fixture", phase: .failed, message: "Fixture error"))
        #expect(try text(in: render(row, height: 40, name: "working-retry")).contains("Retry"))
        var offline = source
        offline.online = false
        browser.receive(sources: [offline], attempt: nil)
        #expect(try text(in: render(row, height: 40, name: "working-unavailable")).contains("Unavailable"))
        #expect(store.navigationAttempt == nil)
    }

    @Test
    func recentIdleRowsKeepDestinationsWithoutRedundantLabelsOrIdentity() async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let agents = ["First target", "Second target"].enumerated().map { index, title in
            AgentInfo(paneID: "compact-pane-\(index)", title: title, status: .idle,
                      workspace: "herdling", cwd: "/fixture", updatedAt: Date(timeIntervalSince1970: Double(2 - index)))
        }
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: agents, online: true)], online: true, error: nil)
        let destinations = agents.map { NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: $0.paneID) }
        let browser = NavigationBrowser()
        browser.open(sources: [source, SourceInfo(descriptor: .remote("offline-host"), sessions: [], online: false, error: "fixture offline")],
                     attempt: nil, keyboard: false, expandedSourceID: nil)
        let visible = try text(in: render(AgentListView(store: store, browser: browser), height: 160, name: "compact-recent"))
        // OCR can lose a final glyph; verify distinct rendered rows and exact model labels separately.
        #expect(visible.contains("First") && visible.contains("Second"))
        #expect(browser.quickIDs == destinations)
        for (destination, agent) in zip(destinations, agents) {
            #expect(browser.presentation(for: destination).title == agent.title)
        }
        #expect(!visible.contains("Recent jumps"))
        #expect(!visible.contains("ready"))
        #expect(!visible.contains("default"))
        #expect(!visible.contains("Some sources"))
        #expect(fittingHeight {
            NavigationList(store: store, browser: browser).environment(\.navigationBrowser, browser)
        } == 82, "Two 40pt destinations and a 2pt gap; no title or offline warning row")
        browser.moveSelection(by: 1)
        #expect(browser.activateSelection() == destinations.first, "Removing display metadata must preserve exact navigation identity")
    }

    @Test
    func defaultPanelShowsAttentionWithoutExpandingDirectory() async throws {
        let defaults = PreviewFixtures.renderDefaults()
        defaults.set("", forKey: "expanded.source")
        let store = PreviewFixtures.makeStore(defaults: defaults)
        store.start()
        defer { store.stop() }
        for _ in 0..<2_000 where store.sources.first?.sessions.isEmpty != false {
            await Task.yield()
        }
        #expect(store.sources.first?.sessions.isEmpty == false)

        let image = try render(AgentListView(store: store), height: 360, name: "initial-quick")
        let visibleText = try text(in: image)
        // These fixture identities must be visible immediately, regardless of saved folds.
        for title in ["fix auth retry loop", "docs pass", "README rewrite"] {
            #expect(visibleText.contains(title), "Attention target missing from initial panel: \(title). OCR: \(visibleText)")
        }
        #expect(!visibleText.contains("Recent jumps"), "Priority rows have no separate navigation-history caption")
    }

    @Test
    func quickRowsAndFixedHeaderHaveDistinctNativeHeights() async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let browser = NavigationBrowser(sources: store.sources)
        let destination = try #require(browser.quickIDs.first)
        let rowHeight = fittingHeight {
            QuickNavigationRow(store: store, browser: browser, destination: destination)
                .environment(\.navigationBrowser, browser)
        }
        #expect(rowHeight == 40)
        #expect(fittingHeight { NavigationHeader(browser: browser) } == 38)
        #expect(fittingHeight {
            HoverRow(accessibilityText: "ordinary", action: {}) { _ in
                RowSymbol(symbol: "desktopcomputer", tint: Theme.Hue.blue)
                Text("Ordinary row")
            }
        } == 32)
    }

    @Test
    func completeHeightIncludesFixedHeaderAndUnclippedList() async {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let browser = NavigationBrowser(sources: store.sources)
        for mode in [NavigationBrowser.Mode.quick, .all] {
            browser.setMode(mode)
            if mode == .all { browser.toggleSource(SourceDescriptor.local.id) }
            let listHeight = fittingHeight {
                NavigationList(store: store, browser: browser)
                    .environment(\.navigationBrowser, browser)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Top hit-area inset1 + visual margin5 =6 visible; footer is6.
            let expected = 38 + 4 + listHeight + 7
            for viewport in [CGFloat(120), 700] {
                let capture = NavigationMeasuredHeight()
                let hosted = host(
                    AgentListView(store: store, browser: browser)
                        .onPreferenceChange(PanelContentHeightKey.self) { height in
                            MainActor.assumeIsolated { capture.value = height }
                        },
                    height: viewport
                )
                #expect(abs(capture.value - expected) < 0.5, "\(mode): header + gap + intrinsic list + insets must not depend on viewport \(viewport)")
                #expect(capture.value > 120)
                hosted.window.close()
            }
        }
    }

    @Test
    func emptySnapshotReportsNewAttentionWithoutClaimingThereIsNone() async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", groups: [], online: true)], online: true, error: nil)
        let browser = NavigationBrowser(sources: [source])
        browser.open(sources: [source], attempt: nil, keyboard: false, expandedSourceID: nil)
        var live = source
        live.sessions[0].groups = [AgentGroup(id: "new-workspace", name: "new-workspace", agents: [
            AgentInfo(paneID: "new-pane", title: "New attention target", status: .blocked, workspace: "new-workspace", cwd: "/fixture", updatedAt: .now)
        ])]
        browser.receive(sources: [live], attempt: nil)
        #expect(browser.quickIDs.isEmpty)
        #expect(browser.quickCandidateCount == 1)
        let visible = try text(in: render(AgentListView(store: store, browser: browser), height: 220, name: "new-attention-empty-snapshot"))
        #expect(!visible.contains("No agents need attention"), "An empty browsing snapshot must not contradict live attention")
        #expect(!visible.contains("New attention target"), "New targets wait for explicit list update")
        #expect(visible.lowercased().contains("reopen"), "New activity needs one brief reopening hint. OCR: \(visible)")
        #expect(!visible.contains("working"), "Empty state must not add a working-count row")
        #expect(visible.components(separatedBy: "Sources").count - 1 == 1, "The fixed switch already provides Sources")
        #expect(fittingHeight { NavigationList(store: store, browser: browser).environment(\.navigationBrowser, browser) } == 40,
                "Empty state is one quiet row, not an illustration and action stack")
        live.sessions[0].groups[0].agents = [AgentInfo(paneID: "new-pane", title: "New working target", status: .working, workspace: "new-workspace", cwd: "/fixture", updatedAt: .now)]
        browser.receive(sources: [live], attempt: nil)
        let working = try text(in: render(AgentListView(store: store, browser: browser), height: 220, name: "new-working-empty-snapshot"))
        #expect(!working.contains("working"))
        #expect(working.lowercased().contains("reopen"), "Working arrivals also wait for reopening. OCR: \(working)")
    }

    @Test
    func offlineSessionDoesNotHideCoverageFromOnlineSibling() async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let source = SourceInfo(descriptor: .local, sessions: [
            SessionInfo(name: "offline", groups: [], online: false),
            SessionInfo(name: "online", agents: [AgentInfo(paneID: "online-pane", title: "Online sibling target", status: .blocked, workspace: "fixture", cwd: "/fixture", updatedAt: .now)], online: true)
        ], online: true, error: nil)
        let browser = NavigationBrowser(sources: [source])
        let visible = try text(in: render(AgentListView(store: store, browser: browser), height: 220, name: "partial-session-coverage"))
        #expect(!visible.contains("Status unavailable"), "One unavailable session must not imply total source unavailability")
        #expect(visible.contains("Online sibling target"))
    }

    @Test
    func emptyNamedSessionHasOneActionAndOneRow() async {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let session = SessionInfo(name: "Named empty session", groups: [], online: true)
        let height = fittingHeight {
            SessionRoster(store: store, source: .local, session: session, branches: [:], showHeader: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        #expect(height == 32, "The clickable named session header already opens the session; a second same-ID action would highlight twice")
        #expect(fittingHeight {
            SessionRoster(store: store, source: .local, session: session, branches: [:], showHeader: false)
                .fixedSize(horizontal: false, vertical: true)
        } == 32, "An empty session without a visible header still needs its Open action")
    }

    @Test
    func keyboardSelectionScrollsWithoutMovingFixedControlsOrNavigating() async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let agents = (0..<30).map { index in
            AgentInfo(paneID: "fixture-pane-\(index)", title: String(format: "Navigation target %02d", index), status: .done, workspace: "fixture-workspace", cwd: "/fixture", updatedAt: Date(timeIntervalSince1970: 0))
        }
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: agents, online: true)], online: true, error: nil)
        let browser = NavigationBrowser(sources: [source])
        browser.open(sources: [source], attempt: nil, keyboard: false, expandedSourceID: nil)
        let hosted = host(AgentListView(store: store, browser: browser), height: 220)
        defer { hosted.window.close() }
        let initial = try text(in: snapshot(hosted.view, name: "scroll-initial"))
        #expect(initial.contains("Navigation target 00"))
        #expect(!initial.contains("Navigation target 29"))
        for _ in 0..<30 { browser.moveSelection(by: 1) }
        try await Task.sleep(for: .milliseconds(200))
        hosted.view.layoutSubtreeIfNeeded()
        let selected = try text(in: snapshot(hosted.view, name: "scroll-selected"))
        #expect(selected.contains("Navigation target 29"), "Selection must scroll the selected identity fully into view. OCR: \(selected)")
        #expect(selected.contains("Activity") && selected.contains("Sources"), "The view switch must stay outside the scroll viewport")
        #expect(!selected.contains("Update list"))
        #expect(!selected.contains("Navigation target 00"))
        #expect(store.navigationAttempt == nil, "Browsing and scrolling must not submit a jump")
    }

    @Test
    func rendersPriorityRowsAllFailureAndRecoveryInBothAppearances() async throws {
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }
        let failed = NavigationDestination.agent(
            sourceID: SourceDescriptor.local.id, sessionName: "default", paneID: "w1:fix auth retry loop"
        )
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            let browser = NavigationBrowser(sources: store.sources)
            browser.open(sources: store.sources, attempt: nil, keyboard: true, expandedSourceID: SourceDescriptor.local.id)
            let quick = try render(AgentListView(store: store, browser: browser), height: 420, name: "quick-\(name)", scheme: scheme)
            // Keep glyphs and trailing readouts out of title recognition, not out of the artifact.
            let scale = CGFloat(quick.width) / Theme.Size.panelWidth
            let titles = try #require(quick.cropping(to: CGRect(x: 36 * scale, y: 40 * scale,
                width: 280 * scale, height: CGFloat(quick.height) - 40 * scale)))
            let quickText = try text(in: titles)
            #expect(quickText.contains("fix auth retry loop"), "The highlighted title must stay readable")
            #expect(quickText.contains("Clash Verge TUN"), "Recent idle appears without a prior navigation")
            #expect(quickText.contains("genre-unit-validation"), "Working targets still appear without duplicate state text")

            browser.receive(sources: store.sources, attempt: NavigationAttempt(destination: failed, title: "fix auth retry loop", subtitle: "Local / default / assessment", phase: .failed, message: "Fixture client activation failed"))
            let failure = try render(AgentListView(store: store, browser: browser), height: 380, name: "failed-\(name)", scheme: scheme)
            #expect(try text(in: failure).contains("Retry"))

            browser.setMode(.all)
            let all = try render(AgentListView(store: store, browser: browser), height: 620, name: "all-\(name)", scheme: scheme)
            #expect(try text(in: all).contains("genre-unit-validation"), "Sources must preserve the nested roster")

            let vanished = NavigationDestination.agent(sourceID: "removed-source", sessionName: "old-session", paneID: "removed-pane")
            browser.open(sources: store.sources, attempt: NavigationAttempt(destination: vanished, title: "Last failed target", subtitle: "Removed / old-session / worktree", phase: .failed, message: "Target no longer exists"), keyboard: false, expandedSourceID: nil)
            let recovery = try render(AgentListView(store: store, browser: browser), height: 500, name: "recovery-\(name)", scheme: scheme)
            #expect(try text(in: recovery).contains("Last failed target"), "Missing failed target must retain a recovery row")
        }
        print("Navigation render artifacts: \(directory.path)")
    }

    private func movePointer(in hosted: (view: NSHostingView<AnyView>, window: NSWindow), to point: NSPoint) throws {
        let location = hosted.view.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        // Deliver only to this offscreen window's tracking owners, never to the user's desktop.
        var views: [NSView] = [hosted.view]
        while let view = views.popLast() {
            views += view.subviews
            guard view.visibleRect.contains(view.convert(location, from: nil)) else { continue }
            for area in view.trackingAreas where area.options.contains(.mouseMoved) {
                (area.owner as? NSResponder)?.mouseMoved(with: event)
            }
        }
    }

    private func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func render(_ view: some View, height: CGFloat, name: String, scheme: ColorScheme = .dark) throws -> CGImage {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApplication.shared.appearance = previous }
        // Off-screen renders have no glass behind them; a plain backdrop keeps OCR on the ink.
        let hosted = host(view.environment(\.colorScheme, scheme).background(scheme == .dark ? Color.black : Color.white), height: height, scheme: scheme)
        defer { hosted.window.close() }
        return try snapshot(hosted.view, name: name)
    }

    private func snapshot(_ hosting: NSHostingView<AnyView>, name: String) throws -> CGImage {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        return try #require(bitmap.cgImage)
    }

    private func fittingHeight(@ViewBuilder _ view: () -> some View) -> CGFloat {
        let hosted = host(view(), height: 800)
        defer { hosted.window.close() }
        return hosted.view.fittingSize.height
    }

    private func host(_ view: some View, height: CGFloat, scheme: ColorScheme = .dark) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = appearance
        defer { NSApplication.shared.appearance = previous }
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.appearance = appearance
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: height)
        let window = NSWindow(contentRect: hosting.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.current.run(until: Date().addingTimeInterval(Theme.Duration.expand * 2))
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }
}

@MainActor
private final class NavigationMeasuredHeight {
    var value: CGFloat = 0
}
