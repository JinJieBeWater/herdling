import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite @MainActor
struct PanelChromeTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func currentViewAndExpandedSourceDoNotLeavePersistentSurfaces(scheme: ColorScheme) throws {
        let browser = NavigationBrowser()
        let activity = try render(NavigationHeader(browser: browser), scheme: scheme)
        browser.setMode(.all)
        let sources = try render(NavigationHeader(browser: browser), scheme: scheme)
        for image in [activity, sources] {
            #expect((0..<200).allSatisfy { alpha(image, x: CGFloat($0), y: 7) < 0.01 },
                    "Neither view choice keeps a surface after the pointer leaves")
        }
        func activityInk(_ image: NSBitmapImageRep) -> CGFloat {
            (12..<88).reduce(0) { total, x in
                total + (10..<28).reduce(0) { $0 + alpha(image, x: CGFloat(x), y: CGFloat($1)) }
            }
        }
        #expect(activityInk(activity) > activityInk(sources) * 1.2,
                "The current view remains distinct through its ink, not a filled plate")

        let store = PreviewFixtures.makeStore()
        let source = SourceInfo(descriptor: .local, sessions: [], online: true)
        let collapsed = try render(SourceOutline(store: store, source: source, isExpanded: false, onToggle: {}), scheme: scheme)
        let expanded = try render(SourceOutline(store: store, source: source, isExpanded: true, onToggle: {}), scheme: scheme)
        for image in [collapsed, expanded] {
            #expect(alpha(image, x: 210, y: 19) < 0.01,
                    "Expansion is a directory state, not a permanent row highlight")
        }
        let arrowDifference = (396..<416).reduce(CGFloat.zero) { total, x in
            total + (10..<28).reduce(CGFloat.zero) {
                $0 + abs(alpha(expanded, x: CGFloat(x), y: CGFloat($1)) - alpha(collapsed, x: CGFloat(x), y: CGFloat($1)))
            }
        }
        #expect(arrowDifference > 1, "The disclosure arrow still expresses expansion")
        #expect(store.navigationAttempt == nil)
    }

    @Test
    func keyboardHighlightFollowsTheVisibleFooterTurn() throws {
        let source = SourceInfo(descriptor: .local, sessions: [], online: true)
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        browser.setMode(.all)
        browser.moveSelection(by: 1)
        let row = HoverRow(minHeight: 40, verticalPadding: 0, accessibilityText: "footer", action: {}) { _ in
            Color.clear.frame(height: 22)
        }.navigationRow(.source(source.id))
        let image = try render(VStack(spacing: 8) {
            Color.clear.frame(height: 40)
            row
        }.padding(.horizontal, Theme.Spacing.panelInset).rosterBoundary()
            .environment(\.navigationBrowser, browser))
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        for y in [84, 86, 88, 90, 92] {
            let first = try #require((Int(6 * scale)..<Int(30 * scale)).first {
                alpha(image, x: CGFloat($0) / scale, y: CGFloat(y)) > 0.01
            })
            let strongest = (0...4).map {
                alpha(image, x: CGFloat(first + $0) / scale, y: CGFloat(y))
            }.max()!
            #expect(strongest > 0.25, "Keyboard highlight must follow the visible footer corner")
        }
    }

    @Test
    func settingsSubtitleUsesTheNativeSecondaryTreatment() throws {
        let actual = try render(SettingsLabel(title: "Title", subtitle: "Subtitle")
            .frame(maxWidth: .infinity, alignment: .leading))
        let reference = try render(VStack(alignment: .leading, spacing: 2) {
            Text("Title").lineLimit(1)
            Text("Subtitle").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).truncationMode(.middle)
        }.frame(maxWidth: .infinity, alignment: .leading))
        let matches = (0..<70).allSatisfy { x in
            (18..<30).allSatisfy { y in
                abs(alpha(actual, x: CGFloat(x), y: CGFloat(y)) - alpha(reference, x: CGFloat(x), y: CGFloat(y))) < 0.005
            }
        }
        #expect(matches, "Native Form subtitles use the system secondary ink, not the glass-panel ramp")
    }

    @Test
    func panelBackgroundsMatchMenuShellClearanceAndCornerTurn() throws {
        if #available(macOS 26.0, *) {
            let glass = panelGlass(wrapping: NSView(), cornerRadius: Theme.Radius.panel)
            #expect(glass.cornerRadius == 12 && glass.layer?.cornerRadius == 12,
                    "The main shell follows the measured native NSMenu 12pt glass radius")
        }
        let content = VStack(spacing: 8) {
            ForEach(0..<2) { _ in
                keyboardRow(height: 40)
            }
        }.fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.panelInset).rosterBoundary()
        let image = try render(content)
        let height = NSHostingView(rootView: content.frame(width: Theme.Size.panelWidth)).fittingSize.height
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        let lastInk = try #require((0..<Int(150 * scale)).last {
            alpha(image, x: 210, y: CGFloat($0) / scale) > 0.01
        })
        let bottom = CGFloat(lastInk + 1) / scale
        #expect(abs(height - bottom - 6) <= 0.5,
                "Bottom background-to-shell clearance matches the compact 6pt side and navigation gutters")
        let reference = try render(RoundedRectangle(cornerSize: CGSize(width: 6, height: 6), style: .continuous)
            .fill(Theme.Colors.highlight).frame(width: 408, height: 88)
            .padding(.top, 6).padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading))
        for y in 82..<94 {
            let actualEdge = try #require((0..<Int(24 * scale)).first {
                alpha(image, x: CGFloat($0) / scale, y: CGFloat(y)) > 0.5
            })
            let referenceEdge = try #require((0..<Int(24 * scale)).first {
                alpha(reference, x: CGFloat($0) / scale, y: CGFloat(y)) > 0.5
            })
            #expect(abs(actualEdge - referenceEdge) <= 1,
                    "The visible footer contour follows the independent 6pt reference within one raster pixel")
        }
        let shell = try render(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black).frame(width: 420, height: height))
        let step = 1 / scale
        let shellEdge: [CGPoint] = (0..<Int(45 * scale)).flatMap { x in
            (Int((height - 45) * scale)..<Int(height * scale)).compactMap { y -> CGPoint? in
                let point = CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
                guard alpha(shell, x: point.x, y: point.y) > 0.5 else { return nil }
                let left = point.x == 0 || alpha(shell, x: point.x - step, y: point.y) <= 0.5
                let below = point.y + step >= height || alpha(shell, x: point.x, y: point.y + step) <= 0.5
                return left || below ? point : nil
            }
        }
        #expect(!shellEdge.isEmpty)
        for y in stride(from: height - 20, through: height - 7, by: 2) {
            let edgeX = try #require((0..<Int(35 * scale)).first {
                alpha(image, x: CGFloat($0) / scale, y: y) > 0.01
            })
            let point = CGPoint(x: CGFloat(edgeX) / scale, y: y)
            let gap = try #require(shellEdge.map { hypot(point.x - $0.x, point.y - $0.y) }.min())
            #expect(abs(gap - 6) <= 1.5, "Rendered corner clearance stays near 6pt, including raster uncertainty: \(gap)")
        }
    }

    @Test
    func navigationAndRosterKeepGlyphAndTitleAnchors() throws {
        let store = PreviewFixtures.makeStore()
        defer { store.stop() }
        let agent = AgentInfo(paneID: "alignment-fixture", title: "Activity", status: .done,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let source = SourceInfo(descriptor: .local,
                                sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        let image = try render(NavigationPanel(store: store, browser: browser)
            .environment(\.navigationBrowser, browser))
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        func fillStart(at y: CGFloat) throws -> CGFloat {
            let x = try #require((0..<Int(40 * scale)).first {
                alpha(image, x: CGFloat($0) / scale, y: y) > 0.01
            })
            return CGFloat(x) / scale
        }
        func glyphCenter(around y: CGFloat) throws -> CGFloat {
            let surface = try #require(image.colorAt(x: Int(210 * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
            let columns = (Int(12 * scale)..<Int(34 * scale)).filter { x in
                (Int((y - 13) * scale)..<Int((y + 13) * scale)).contains { yy in
                    guard let color = image.colorAt(x: x, y: yy)?.usingColorSpace(.deviceRGB) else { return false }
                    return max(abs(color.redComponent - surface.redComponent),
                               abs(color.greenComponent - surface.greenComponent),
                               abs(color.blueComponent - surface.blueComponent),
                               abs(color.alphaComponent - surface.alphaComponent)) > 0.3
                }
            }
            return CGFloat(try #require(columns.first) + #require(columns.last)) / (2 * scale)
        }
        let rosterEdge = try fillStart(at: 63)
        #expect(abs(rosterEdge - 6) <= 0.5, "The shared visual gutter follows the compact menu grid")
        #expect(abs(try glyphCenter(around: 20) - 23) <= 1,
                "Menu-style content padding places the first glyph centre at 23pt")
        #expect(abs(try glyphCenter(around: 20) - glyphCenter(around: 63)) <= 0.5,
                "Independent symbol slots align their visible centres")
        let navigationTitle = try #require(firstTextInkX(image, around: 20, from: 34))
        // Past the glyph: on the keyboard highlight the status mark is white ink too.
        let rosterTitle = try #require(firstTextInkX(image, around: 57, from: 34))
        #expect(abs(navigationTitle - 40) <= 1.5, "The unindented title anchor follows 6pt row content padding")
        #expect(abs(navigationTitle - rosterTitle) <= 0.5, "Navigation and unindented roster titles share a column")
        #expect(store.navigationAttempt == nil, "Inspecting the alignment never submits navigation")
    }

    @Test
    func viewChoiceTypographyMatchesRegularControlText() throws {
        let header = try render(NavigationHeader(browser: NavigationBrowser()))
        let textStart = Theme.Spacing.navigationContentInset + Theme.Size.navigationIcon + Theme.Spacing.navigationContentGap
        let titleWidth = NSHostingView(rootView: Text("Activity").font(Theme.Typography.rowTrailing)).fittingSize.width
        let optionEnd = textStart + titleWidth + Theme.Spacing.md
        let reference = try render(Text("Activity")
            .font(Theme.Typography.rowTrailing)
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.leading, textStart)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Theme.Size.navigationHeaderHeight))
        func inkWidth(_ image: NSBitmapImageRep) throws -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
            let columns = (Int(textStart * scale)..<Int(optionEnd * scale)).filter { x in
                (Int(9 * scale)..<Int(29 * scale)).contains { y in
                    // The control's ink, independently of the surface behind it.
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.genericGray) else { return false }
                    return color.alphaComponent > 0.4 && color.whiteComponent < 0.5
                }
            }
            return CGFloat(try #require(columns.last) - #require(columns.first) + 1) / scale
        }
        #expect(abs(try inkWidth(header) - inkWidth(reference)) <= 1.5,
                "View choices use regular control type, not the heavier section-title role")
    }

    @Test
    func statusGlyphTurnsWhiteOnTheAccentHighlight() throws {
        let glyph = RowSymbol(symbol: "circle.fill", tint: Color(nsColor: StatusPalette.working))
        let image = try render(glyph.frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.highlight).environment(\.backgroundProminence, .increased))
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        let center = try #require(image.colorAt(x: Int(11 * scale), y: Int(11 * scale))?.usingColorSpace(.deviceRGB))
        #expect(min(center.redComponent, center.greenComponent, center.blueComponent) > 0.9,
                "A working-blue mark would disappear into the accent, so it takes white ink like a native menu icon")
    }

    @Test
    func unavailableKeyboardTargetStaysVisibleWithoutTheAccent() throws {
        let agent = AgentInfo(paneID: "unavailable-fixture", title: "Unavailable fixture", status: .working,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let session = SessionInfo(name: "default", agents: [agent], online: true)
        let source = SourceInfo(descriptor: .local, sessions: [session], online: true)
        let browser = NavigationBrowser()
        // A real visit is frozen; receive() outside a visit intentionally rebuilds the list.
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        let destination = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: agent.paneID)
        let row = HoverRow(accessibilityText: agent.title, action: {}) { _ in
            Color.clear.frame(height: Theme.Size.rowIcon)
        }.navigationRow(.destination(destination)).environment(\.navigationBrowser, browser)
        let online = try render(row)
        #expect(try isAccent(online, x: 210, y: 16), "An available keyboard target takes the native menu highlight")
        browser.receive(sources: [SourceInfo(descriptor: .local, sessions: [session], online: false, error: "Offline")], attempt: nil)
        #expect(!browser.isAvailable(destination))
        let unavailable = try render(row)
        #expect(try !isAccent(unavailable, x: 210, y: 16), "Disabled rows do not promise interaction with the accent")
        #expect(alpha(unavailable, x: 210, y: 16) > 0.3, "Keyboard inspection remains visible independently of availability")
        #expect(browser.selection == .destination(destination), "A source outage does not move the inspected target")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func keyboardTargetsUseMenuHighlightAndWhiteInk(scheme: ColorScheme) throws {
        let store = PreviewFixtures.makeStore()
        let agent = AgentInfo(paneID: "highlight-fixture", title: "Highlight fixture", status: .working,
                              workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let source = SourceInfo(descriptor: .local,
                                sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true)
        let browser = NavigationBrowser()
        let destination = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: agent.paneID)
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        let row = QuickNavigationRow(store: store, browser: browser, destination: destination)
            .environment(\.navigationBrowser, browser)
        let active = try render(row, scheme: scheme)
        #expect(try isAccent(active, x: 210, y: 20, scheme: scheme))
        func hasWhiteInk(_ image: NSBitmapImageRep, in rect: CGRect) -> Bool {
            let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
            return (Int(rect.minX * scale)..<Int(rect.maxX * scale)).contains { x in
                (Int(rect.minY * scale)..<Int(rect.maxY * scale)).contains { y in
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.9
                }
            }
        }
        #expect(hasWhiteInk(active, in: CGRect(x: 8, y: 5, width: 22, height: 30)), "Status glyph turns white")
        #expect(hasWhiteInk(active, in: CGRect(x: 36, y: 4, width: 150, height: 18)), "The title turns white too")
        #expect(browser.selectForInspection(destination))
        browser.beginInspection()
        let inspecting = try render(row, scheme: scheme)
        #expect(try !isAccent(inspecting, x: 210, y: 20, scheme: scheme),
                "Opening actions hands the accent to the command menu, not its inspected target")
        browser.endInspection(keyboard: false)
        browser.setMode(.all)
        browser.moveSelection(by: 1)
        let sourceHeader = try render(SourceOutline(store: store, source: source, isExpanded: false, onToggle: {})
            .environment(\.navigationBrowser, browser), scheme: scheme)
        #expect(browser.keyboardSelection == .source(source.id))
        #expect(try isAccent(sourceHeader, x: 210, y: 19, scheme: scheme), "Source headers share the same highlight")
        #expect(store.navigationAttempt == nil, "Highlighting never submits a terminal jump")
    }

    private func isAccent(_ image: NSBitmapImageRep, x: CGFloat, y: CGFloat, scheme: ColorScheme = .light) throws -> Bool {
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        let reference = try render(Rectangle().fill(Color(nsColor: .selectedContentBackgroundColor)), scheme: scheme)
        guard let color = image.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB),
              let accent = reference.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { return false }
        return color.alphaComponent > 0.9
            && abs(color.redComponent - accent.redComponent) < 0.03
            && abs(color.greenComponent - accent.greenComponent) < 0.03
            && abs(color.blueComponent - accent.blueComponent) < 0.03
    }

    @Test
    func retryAndStatusSummaryShareTheirTrailingTextEdge() throws {
        let store = PreviewFixtures.makeStore()
        let agent = AgentInfo(paneID: "fixture", title: "Fixture", status: .working, workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        let online = SourceInfo(descriptor: .local, sessions: [SessionInfo(name: "default", agents: [agent], online: true)], online: true, error: nil)
        let offline = SourceInfo(descriptor: .remote("offline"), sessions: [], online: false, error: "fixture", retryAt: Date(timeIntervalSince1970: 1_000))
        // Isolate headers: directory body height must not turn this alignment check into a
        // comparison with an agent row when one source is expanded by default.
        let image = try render(VStack(spacing: Theme.Spacing.sectionSpacing) {
            SourceOutline(store: store, source: online, isExpanded: false, onToggle: {})
            SourceOutline(store: store, source: offline, isExpanded: false, onToggle: {})
        }.padding(.horizontal, Theme.Spacing.panelInset).rosterBoundary())
        func trailingInk(around center: CGFloat) throws -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
            for x in stride(from: Int(389 * scale), through: Int(250 * scale), by: -1) {
                for y in Int((center - 10) * scale)..<Int((center + 10) * scale) {
                    if (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { return CGFloat(x) / scale }
                }
            }
            throw AlignmentInkError.missing
        }
        let statusRight = try trailingInk(around: Theme.Spacing.panelInset + 19)
        let retryRight = try trailingInk(around: Theme.Spacing.panelInset + 61)
        #expect(abs(statusRight - retryRight) <= 2, "Trailing text ends at \(statusRight) versus \(retryRight); no empty-summary gap")
    }

    @Test(arguments: [Theme.Size.rowMinHeight, Theme.Size.navigationHeaderHeight, Theme.Size.quickRowHeight])
    func bottomHighlightFollowsPanelWithoutRoundingInteriorCorners(rowHeight: CGFloat) throws {
        let gap: CGFloat = 8
        let lastTop = Theme.Spacing.panelInset + rowHeight + gap
        let lastBottom = lastTop + rowHeight
        let image = try render(
            VStack(spacing: gap) {
                ForEach(0..<2) { _ in
                    keyboardRow(height: rowHeight)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.panelInset)
            .rosterBoundary()
        )
        // 32pt bodies, 38pt headers and 40pt Quick rows share the real lower content boundary.
        #expect(alpha(image, x: Theme.Spacing.panelInset + 1, y: lastBottom - 1) < 0.01)
        #expect(alpha(image, x: Theme.Size.panelWidth - Theme.Spacing.panelInset - 1, y: lastBottom - 1) < 0.01)
        #expect(alpha(image, x: Theme.Spacing.panelInset + 6, y: lastBottom - 1) > 0.01)
        #expect(alpha(image, x: Theme.Spacing.panelInset + 1, y: lastTop + 4) > 0.01)
        #expect(alpha(image, x: Theme.Spacing.panelInset + 1, y: Theme.Spacing.panelInset + rowHeight - 4) > 0.01)
    }

    @Test
    func nestedTitlesAdvanceOneVisibleLevel() throws {
        let store = PreviewFixtures.makeStore()
        let image = try render(
            SessionRoster(store: store, source: .local, session: PreviewFixtures.nestedSession(),
                          branches: [:], showHeader: true, indent: 12)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        )
        // Session, sole-worktree space/agent, branched space, Main/agent, topic/agent.
        // Text columns advance 12pt per visible level; both space headings share a column.
        let centers: [CGFloat] = [16, 50, 84, 124, 158, 192, 232, 266]
        let columns: [CGFloat] = [54, 66, 78, 66, 78, 90, 78, 90]
        for (y, x) in zip(centers, columns) {
            let actual = try #require(firstTextInkX(image, around: y))
            #expect(abs(actual - x) <= 1, "text at y=\(y) starts at \(actual), expected \(x)")
        }
    }

    @Test
    func sectionIconsUseBareGlyphsWithoutPlates() throws {
        let store = PreviewFixtures.makeStore()
        // Neither expansion state adds a plate around the glyph.
        for source in store.sources {
            for expanded in [false, true] {
                let image = try render(SourceOutline(store: store, source: source, isExpanded: expanded, onToggle: {})
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.panelInset).rosterBoundary())
                let centerY = Theme.Spacing.panelInset + 19
                #expect(abs(alpha(image, x: Theme.Spacing.panelInset + Theme.Spacing.rowHorizontal + 1, y: centerY - 10)
                    - alpha(image, x: 210, y: centerY - 10)) < 0.01)
                let ink = (12..<34).contains { x in
                    (Int(centerY) - 11..<Int(centerY) + 11).contains { y in
                        // Secondary ink is about half alpha; anything well above the row fill is glyph.
                        alpha(image, x: CGFloat(x), y: CGFloat(y)) > 0.3
                    }
                }
                #expect(ink, "leading glyph missing for \(source.id), expanded=\(expanded)")
            }
        }
    }

    @Test
    func topHighlightFollowsPanelWhileOrdinaryRowsStayCompact() throws {
        let store = PreviewFixtures.makeStore()
        let browser = NavigationBrowser(sources: store.sources)
        browser.setMode(.all)
        browser.toggleSource(SourceDescriptor.local.id)
        browser.moveSelection(by: 1)
        let image = try render(
            NavigationList(store: store, browser: browser)
                .environment(\.navigationBrowser, browser)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.panelInset)
                .rosterBoundary()
        )

        // First and ordinary rows share the compact menu's 6pt corners and inset.
        #expect(alpha(image, x: 7, y: 7) < 0.01)
        #expect(alpha(image, x: Theme.Size.panelWidth - 7, y: 7) < 0.01)
        #expect(alpha(image, x: 13, y: 8) > 0.01)
        #expect(alpha(image, x: 7, y: 40) > 0.01)

        let ordinary = try render(keyboardRow())
        #expect(alpha(ordinary, x: 4, y: 4) > 0.01)
    }

    private func keyboardRow(height: CGFloat = Theme.Size.rowMinHeight) -> some View {
        let source = SourceInfo(descriptor: .local, sessions: [], online: true)
        let browser = NavigationBrowser()
        browser.open(sources: [source], attempt: nil, keyboard: true, expandedSourceID: nil)
        browser.setMode(.all)
        browser.moveSelection(by: 1)
        return HoverRow(minHeight: height, verticalPadding: 0, accessibilityText: "highlight fixture", action: {}) { _ in
            Color.clear.frame(height: Theme.Size.rowIcon)
        }.navigationRow(.source(source.id)).environment(\.navigationBrowser, browser)
    }

    private func render(_ view: some View, scheme: ColorScheme = .light) throws -> NSBitmapImageRep {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { app.appearance = previous }
        let hosting = NSHostingView(rootView:
            view.frame(width: Theme.Size.panelWidth)
                .frame(height: 500, alignment: .top)
                .environment(\.colorScheme, scheme)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: 500)
        // Off screen, so the real pointer cannot hover a row into the accent highlight.
        let window = NSWindow(contentRect: hosting.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = app.appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<2 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        RunLoop.current.run(until: Date().addingTimeInterval(Theme.Duration.expand * 2))
        hosting.layoutSubtreeIfNeeded()
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image
    }

    private func alpha(_ image: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        return image.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0
    }

    private func firstTextInkX(_ image: NSBitmapImageRep, around center: CGFloat, from start: CGFloat = 0) -> CGFloat? {
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        // The row's own surface at the search start; ink is whatever departs from it.
        let surface = image.colorAt(x: Int(start * scale), y: Int(center * scale))?.usingColorSpace(.deviceRGB)
        for x in Int(start * scale)..<Int(140 * scale) {
            for y in Int((center - 10) * scale)..<Int((center + 10) * scale) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // All fixture marks are working-blue; neutral ink is the title, not the glyph.
                if color.alphaComponent > 0.3,
                   abs(color.redComponent - color.blueComponent) < 0.05,
                   abs(color.greenComponent - color.blueComponent) < 0.05,
                   (abs(color.redComponent - (surface?.redComponent ?? 0)) > 0.3
                    || abs(color.alphaComponent - (surface?.alphaComponent ?? 0)) > 0.3) {
                    return CGFloat(x) / scale
                }
            }
        }
        return nil
    }
}

private enum AlignmentInkError: Error { case missing }
