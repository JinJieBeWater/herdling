import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite @MainActor
struct PanelChromeTests {
    @Test
    func viewChoiceTypographyMatchesRegularControlText() throws {
        let header = try render(NavigationHeader(browser: NavigationBrowser()))
        let textStart: CGFloat = 28 // Approved 8pt padding + 14pt navigation slot + 6pt gap.
        let scale = CGFloat(header.pixelsWide) / Theme.Size.panelWidth
        let optionEnd = try #require((5..<200).first { x in
            (header.colorAt(x: Int(CGFloat(x) * scale), y: Int(19 * scale))?.alphaComponent ?? 0) < 0.01
        })
        let reference = try render(Text("Activity")
            .font(Theme.Typography.rowTrailing)
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.leading, textStart)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Theme.Size.navigationHeaderHeight))
        func inkWidth(_ image: NSBitmapImageRep) throws -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
            let columns = (Int(textStart * scale)..<Int(CGFloat(optionEnd) * scale)).filter { x in
                (Int(9 * scale)..<Int(29 * scale)).contains { y in
                    (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4
                }
            }
            return CGFloat(try #require(columns.last) - #require(columns.first) + 1) / scale
        }
        #expect(abs(try inkWidth(header) - inkWidth(reference)) <= 1.5,
                "View choices use regular control type, not the heavier section-title role")
    }

    @Test
    func selectedNavigationSurfaceIsCompactAndSharesSelectionStrength() throws {
        let browser = NavigationBrowser(sources: PreviewFixtures.makeStore().sources)
        let image = try render(
            VStack(spacing: 0) {
                NavigationHeader(browser: browser)
                HoverRow(minHeight: 38, verticalPadding: 0, isSelected: true,
                         accessibilityText: "reference source", action: {}) { _ in
                    Color.clear.frame(height: 22)
                }
            }.rosterBoundary()
        )
        let rowLeft = try #require((0..<40).first { alpha(image, x: CGFloat($0), y: 65) > 0.01 })
        let titleColumn = CGFloat(rowLeft) + 28
        let textLeft = try #require(firstTextInkX(image, around: 27, from: titleColumn))
        #expect(abs(textLeft - titleColumn) <= 2, "Short navigation labels use their own compact symbol slot")
        #expect((16..<30).contains { x in (17..<37).contains { y in
            alpha(image, x: CGFloat(x), y: CGFloat(y)) > 0.4
        } }, "The view's leading slot must contain a role glyph")
        #expect(abs(alpha(image, x: 17, y: 21) - alpha(image, x: 32, y: 21)) < 0.01,
                "No plate around the navigation glyph")
        #expect(alpha(image, x: 12, y: 27) > 0.01)
        #expect(abs(alpha(image, x: 12, y: 27) - alpha(image, x: 12, y: 65)) < 0.005,
                "Current view and selected rows share selection strength, not hover strength")
        #expect(alpha(image, x: 110, y: 42) < 0.01, "No shared track behind the inactive option")
        #expect(alpha(image, x: 24, y: 12) < 0.01, "28pt surface leaves 5pt inside the 38pt hit area")
        #expect(alpha(image, x: 24, y: 14) > 0.01)
        #expect(alpha(image, x: 24, y: 40) > 0.01)
        #expect(alpha(image, x: 24, y: 42) < 0.01)
    }

    @Test
    func unavailableTargetKeepsKeyboardOutlineWithoutInteractionWash() throws {
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
        #expect(alpha(online, x: 210, y: 16) > 0.01)
        browser.receive(sources: [SourceInfo(descriptor: .local, sessions: [session], online: false, error: "Offline")], attempt: nil)
        #expect(!browser.isAvailable(destination))
        let unavailable = try render(row)
        #expect(alpha(unavailable, x: 210, y: 16) < 0.01, "Disabled rows do not promise interaction with a selected wash")
        #expect(alpha(unavailable, x: 210, y: 0) > 0.3, "Keyboard inspection remains visible independently of availability")
        #expect(browser.selection == .destination(destination), "A source outage does not move the inspected target")
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
        }.rosterBoundary())
        func trailingInk(around center: CGFloat) throws -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
            for x in stride(from: Int(389 * scale), through: Int(250 * scale), by: -1) {
                for y in Int((center - 10) * scale)..<Int((center + 10) * scale) {
                    if (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { return CGFloat(x) / scale }
                }
            }
            throw AlignmentInkError.missing
        }
        let statusRight = try trailingInk(around: 27)
        let retryRight = try trailingInk(around: 69)
        #expect(abs(statusRight - retryRight) <= 2, "Trailing text ends at \(statusRight) versus \(retryRight); no empty-summary gap")
    }

    @Test(arguments: [Theme.Size.rowMinHeight, Theme.Size.navigationHeaderHeight, Theme.Size.quickRowHeight])
    func bottomHighlightFollowsPanelWithoutRoundingInteriorCorners(rowHeight: CGFloat) throws {
        let gap: CGFloat = 8
        let lastTop = 8 + rowHeight + gap
        let lastBottom = lastTop + rowHeight
        let image = try render(
            VStack(spacing: gap) {
                ForEach(0..<2) { index in
                    HoverRow(minHeight: rowHeight, verticalPadding: 0, isSelected: true,
                             accessibilityText: "row \(index)", action: {}) { _ in
                        Color.clear.frame(height: Theme.Size.rowIcon)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .rosterBoundary()
        )
        // 32pt bodies, 38pt headers and 40pt Quick rows share the real lower content boundary.
        #expect(alpha(image, x: 12, y: lastBottom - 4) < 0.01)
        #expect(alpha(image, x: Theme.Size.panelWidth - 12, y: lastBottom - 4) < 0.01)
        #expect(alpha(image, x: 22, y: lastBottom - 4) > 0.01)
        #expect(alpha(image, x: 12, y: lastTop + 4) > 0.01)
        #expect(alpha(image, x: 12, y: 8 + rowHeight - 4) > 0.01)
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
        let columns: [CGFloat] = [56, 68, 80, 68, 80, 92, 80, 92]
        for (y, x) in zip(centers, columns) {
            let actual = try #require(firstTextInkX(image, around: y))
            #expect(abs(actual - x) <= 1, "text at y=\(y) starts at \(actual), expected \(x)")
        }
    }

    @Test
    func sectionIconsUseBareGlyphsWithoutPlates() throws {
        let store = PreviewFixtures.makeStore()
        // Selected headers may have a row fill, but no extra plate around their glyph.
        for source in store.sources {
            for expanded in [false, true] {
                let image = try render(SourceOutline(store: store, source: source, isExpanded: expanded, onToggle: {})
                    .fixedSize(horizontal: false, vertical: true).rosterBoundary())
                let centerY: CGFloat = 27
                #expect(abs(alpha(image, x: 17, y: centerY) - alpha(image, x: 210, y: centerY)) < 0.01)
                let ink = (16..<38).contains { x in
                    (Int(centerY) - 11..<Int(centerY) + 11).contains { y in
                        alpha(image, x: CGFloat(x), y: CGFloat(y)) > 0.5
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
        let image = try render(
            NavigationList(store: store, browser: browser)
                .environment(\.navigationBrowser, browser)
                .fixedSize(horizontal: false, vertical: true)
                .rosterBoundary()
        )

        // The first highlight is inset 8pt. Its top corner turns farther in than a
        // normal row, without also rounding its bottom into a capsule.
        #expect(alpha(image, x: 12, y: 12) < 0.01)
        #expect(alpha(image, x: Theme.Size.panelWidth - 12, y: 12) < 0.01)
        #expect(alpha(image, x: 22, y: 12) > 0.01)
        #expect(alpha(image, x: 12, y: 42) > 0.01)

        let ordinary = try render(
            HoverRow(isSelected: true, accessibilityText: "row", action: {}) { _ in
                Color.clear.frame(height: Theme.Size.rowIcon)
            }
        )
        #expect(alpha(ordinary, x: 4, y: 4) > 0.01)
    }

    private func render(_ view: some View) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView:
            view.frame(width: Theme.Size.panelWidth)
                .frame(height: 500, alignment: .top)
                .environment(\.colorScheme, .light)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: 500)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        for x in Int(start * scale)..<Int(140 * scale) {
            for y in Int((center - 10) * scale)..<Int((center + 10) * scale) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // All fixture marks are working-blue; neutral ink is the title, not the glyph.
                if color.alphaComponent > 0.3,
                   abs(color.redComponent - color.blueComponent) < 0.05,
                   abs(color.greenComponent - color.blueComponent) < 0.05 {
                    return CGFloat(x) / scale
                }
            }
        }
        return nil
    }
}

private enum AlignmentInkError: Error { case missing }
