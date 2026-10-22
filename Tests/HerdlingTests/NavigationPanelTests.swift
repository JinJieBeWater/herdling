import AppKit
import SwiftUI
import Testing
import Vision
@testable import Herdling

@Suite(.serialized)
@MainActor
struct NavigationPanelTests {
    private let directory = URL(fileURLWithPath: "/tmp/herdling-navigation-render-\(UUID().uuidString)")

    @Test func mouseInspectionEmphasisEndsWithTheMenuWhileKeyboardFocusRemainsDistinct() throws {
        let store = PreviewFixtures.makeStore()
        let agent = AgentInfo(paneID: "inspect", title: "Inspection fixture", status: .working,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let sources = [SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)]
        let browser = NavigationBrowser()
        browser.open(sources: sources, attempt: nil, keyboard: false, expandedSourceID: nil)
        let target = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "inspect")
        let row = QuickNavigationRow(store: store, browser: browser, destination: target).environment(\.navigationBrowser, browser)
        let normal = try render(row, height: 40, name: "inspection-base")
        let parent = MenuBarPanel()
        parent.setFrame(NSRect(x: 100, y: 100, width: 420, height: 300), display: false)
        parent.orderBack(nil)
        let menu = AgentActionsMenuController(parent: parent, store: store, browser: browser)
        defer { menu.dismiss(returnFocus: false); parent.orderOut(nil) }
        menu.present(for: target)
        let inspecting = try render(row, height: 40, name: "inspection-open")
        menu.dismiss()
        let dismissed = try render(row, height: 40, name: "inspection-dismissed")
        func png(_ image: CGImage) -> Data? { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) }
        #expect(png(inspecting) != png(normal), "The open menu briefly identifies its target")
        #expect(png(dismissed) == png(normal), "Mouse inspection must not leave a keyboard focus wash or outline")
        #expect(browser.selection == .destination(target), "Visual emphasis is separate from exact target identity")
        browser.moveSelection(by: -1)
        let keyboard = try render(row, height: 40, name: "inspection-keyboard")
        #expect(png(keyboard) != png(normal), "Actual keyboard browsing still shows clear focus")
        #expect(store.navigationAttempt == nil)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func mutingLowersRowInkWithoutAddingABadgeOrLosingTheWorkingState(scheme: ColorScheme) throws {
        for activity in [true, false] {
            let store = PreviewFixtures.makeStore()
            let agent = AgentInfo(paneID: "worker", title: "Worker", status: .working,
                                  workspace: "fixture", cwd: "/fixture", updatedAt: .now)
            let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)
            let browser = NavigationBrowser(sources: [source])
            let target = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "worker")
            let row = activity ? AnyView(QuickNavigationRow(store: store, browser: browser, destination: target))
                : AnyView(AgentRow(agent: agent, enabled: true, isFocusPending: false, action: {}, indent: 0, store: store, destination: target))
            let view = row.environment(\.navigationBrowser, browser).background(scheme == .dark ? Color.black : Color.white)
            let height: CGFloat = activity ? 40 : 32
            let name = "muted-\(scheme)-\(activity)"
            let normal = try render(view, height: height, name: name + "-normal", scheme: scheme)
            store.setObserveOnly(true, for: target)
            let muted = try render(view, height: height, name: name + "-muted", scheme: scheme)
            let before = NSBitmapImageRep(cgImage: normal), after = NSBitmapImageRep(cgImage: muted)
            let scale = CGFloat(normal.width) / 420
            func titleInk(_ bitmap: NSBitmapImageRep) -> CGFloat {
                (0..<normal.height).reduce(0) { sum, y in
                    sum + (Int(35 * scale)..<Int(200 * scale)).reduce(0) { sum, x in
                        let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        let brightness = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                        return sum + (scheme == .dark ? brightness : 1 - brightness)
                    }
                }
            }
            let normalInk = titleInk(before), quietInk = titleInk(after)
            #expect(quietInk < normalInk * 0.9, "Muted rows must draw less attention, not add another prominent glyph")
            #expect(quietInk > normalInk * 0.55, "Muted titles must remain legible")
            #expect(normal.width == muted.width && normal.height == muted.height)
            #expect(try text(in: muted).contains("Worker"))
            #expect(browser.presentation(for: target).status == .working)
            func workingChroma(_ bitmap: NSBitmapImageRep) -> CGFloat {
                (0..<normal.height).reduce(0) { sum, y in
                    sum + (Int(8 * scale)..<Int(30 * scale)).reduce(0) { sum, x in
                        let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        return sum + max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
                    }
                }
            }
            let chroma = workingChroma(after), ordinaryChroma = workingChroma(before)
            #expect(chroma > ordinaryChroma * 0.4 && chroma < ordinaryChroma * 0.8, "Working keeps its real hue at a quieter visual weight")
            store.setObserveOnly(false, for: target)
            let restored = try render(view, height: height, name: name + "-restored", scheme: scheme)
            #expect(try text(in: restored).contains("Worker"))
            #expect(NSBitmapImageRep(cgImage: restored).representation(using: .png, properties: [:]) == before.representation(using: .png, properties: [:]), "Unmuting restores normal ink without moving the content")
        }
    }

    @Test
    func observedRowKeepsRealStateAndLegibleTitleWithoutAttentionEmphasis() throws {
        let store = PreviewFixtures.makeStore()
        let agent = AgentInfo(paneID: "child", title: "Child worker", status: .blocked,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let source = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)
        let browser = NavigationBrowser(sources: [source])
        let destination = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "child")
        let row = QuickNavigationRow(store: store, browser: browser, destination: destination).environment(\.navigationBrowser, browser)
        let normal = try render(row, height: 40, name: "observe-normal")
        store.setObserveOnly(true, for: destination)
        let quiet = try render(row, height: 40, name: "observe-quiet")
        let caption = try text(in: quiet)
        #expect(caption.contains("Child worker"))
        #expect(!caption.contains("Observe only"), "An add-on policy does not consume the normal row's text budget")
        #expect(!caption.contains("Needs input"))
        func chromaticGlyphPixels(_ image: CGImage) -> Int {
            let bitmap = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(bitmap.pixelsWide) / 420
            return (Int(8 * scale)..<Int(32 * scale)).reduce(0) { count, y in
                count + (Int(8 * scale)..<Int(30 * scale)).count { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.4 else { return false }
                    return max(color.redComponent, color.greenComponent, color.blueComponent)
                        - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.1
                }
            }
        }
        #expect(chromaticGlyphPixels(normal) > 10)
        #expect(chromaticGlyphPixels(quiet) == 0, "Blocked shape remains but no longer uses attention ink")
        #expect(browser.presentation(for: destination).status == .blocked)
        browser.moveSelection(by: 1)
        #expect(browser.activateSelection() == destination)
        browser.receive(sources: [source], attempt: NavigationAttempt(destination: destination, title: agent.title, subtitle: "fixture", phase: .pending, message: nil))
        #expect(try text(in: render(row, height: 40, name: "observe-opening")).contains("Opening"))
        browser.receive(sources: [source], attempt: NavigationAttempt(destination: destination, title: agent.title, subtitle: "fixture", phase: .failed, message: "Fixture error"))
        #expect(try text(in: render(row, height: 40, name: "observe-retry")).contains("Retry"))
        let workingAgent = AgentInfo(paneID: "child", title: "Child worker", status: .working,
                                     workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let workingSource = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [workingAgent], online: true)], online: true)
        browser.receive(sources: [workingSource], attempt: nil)
        let working = try render(row, height: 40, name: "observe-working")
        #expect(chromaticGlyphPixels(working) > 10, "Working stays visible in its real status colour")
        #expect(try !text(in: working).contains("Observe only"))
        #expect(store.navigationAttempt == nil)
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
    func viewSelectionBelongsOnlyToItsOptionAndDoesNotSubmitNavigation(hitY: CGFloat) async throws {
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
        let wash = try alpha(bitmap, x: Theme.Spacing.navigationVisualInset + 4, y: 19)
        let firstClearColumn = try #require((5..<200).first { try alpha(bitmap, x: CGFloat($0), y: 19) < 0.01 })
        let gap = CGFloat(firstClearColumn) + 1
        #expect(wash > 0.01 && wash < 0.25, "Current view owns one faint selected background")
        #expect(try alpha(bitmap, x: gap + 6, y: 19) < 0.01, "Inactive option must remain transparent")
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
        #expect(try alpha(selectedBitmap, x: Theme.Spacing.navigationVisualInset + 4, y: 19) < 0.01)
        #expect(try alpha(selectedBitmap, x: gap, y: 19) < 0.01, "Adjacent option backgrounds need a clear gap")
        #expect(try alpha(selectedBitmap, x: gap + 6, y: 19) > 0.01)
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
            // Top hit-area inset8 + visual margin5 =13 visible; footer is13.
            let expected = 38 + 4 + listHeight + 21
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
            let quickText = try text(in: quick)
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

    private func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func render(_ view: some View, height: CGFloat, name: String, scheme: ColorScheme = .dark) throws -> CGImage {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { NSApplication.shared.appearance = previous }
        let hosted = host(view.environment(\.colorScheme, scheme), height: height, scheme: scheme)
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
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
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
