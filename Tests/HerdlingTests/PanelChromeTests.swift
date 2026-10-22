import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite @MainActor
struct PanelChromeTests {
    @Test
    func keyboardOutlineFollowsTheVisibleFooterTurn() throws {
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
        for y in [91, 93, 95, 97, 99] {
            let first = try #require((Int(13 * scale)..<Int(36 * scale)).first {
                alpha(image, x: CGFloat($0) / scale, y: CGFloat(y)) > 0.01
            })
            let strongest = (0...4).map {
                alpha(image, x: CGFloat(first + $0) / scale, y: CGFloat(y))
            }.max()!
            #expect(strongest > 0.25, "Keyboard outline must follow the visible corner, not end at a clipped ordinary-row arc")
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
    func panelBackgroundsKeepUniformShellClearanceAndCornerTurn() throws {
        let content = VStack(spacing: 8) {
            ForEach(0..<2) { index in
                HoverRow(minHeight: 40, verticalPadding: 0, isSelected: true,
                         accessibilityText: "footer fixture \(index)", action: {}) { _ in
                    Color.clear.frame(height: 22)
                }
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
        #expect(abs(height - bottom - 13) <= 0.5,
                "Bottom background-to-shell clearance matches the 13pt side and navigation gutters")
        let reference = try render(RoundedRectangle(cornerSize: CGSize(width: 13, height: 13), style: .continuous)
            .fill(Theme.Colors.selection).frame(width: 394, height: 88)
            .padding(.top, 13).padding(.leading, 13)
            .frame(maxWidth: .infinity, alignment: .leading))
        let matches = (14..<35).allSatisfy { x in
            (84..<101).allSatisfy { y in
                abs(alpha(image, x: CGFloat(x), y: CGFloat(y)) - alpha(reference, x: CGFloat(x), y: CGFloat(y))) < 0.005
            }
        }
        #expect(matches, "The visible footer turn uses the same inset in both axes")
        let shell = try render(RoundedRectangle(cornerRadius: 26, style: .continuous)
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
        for y in stride(from: height - 25, through: height - 14, by: 2) {
            let edgeX = try #require((0..<Int(35 * scale)).first {
                alpha(image, x: CGFloat($0) / scale, y: y) > 0.01
            })
            let point = CGPoint(x: CGFloat(edgeX) / scale, y: y)
            let gap = try #require(shellEdge.map { hypot(point.x - $0.x, point.y - $0.y) }.min())
            #expect(abs(gap - 13) <= 1.5, "Rendered corner clearance stays near 13pt, including raster uncertainty: \(gap)")
        }
    }

    @Test
    func navigationAndRosterShareBackgroundGlyphAndTitleAnchors() throws {
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
            let columns = (Int(18 * scale)..<Int(40 * scale)).filter { x in
                (Int((y - 13) * scale)..<Int((y + 13) * scale)).contains { yy in
                    (image.colorAt(x: x, y: yy)?.alphaComponent ?? 0) > 0.35
                }
            }
            return CGFloat(try #require(columns.first) + #require(columns.last)) / (2 * scale)
        }
        let navigationEdge = try fillStart(at: 27)
        let rosterEdge = try fillStart(at: 70)
        #expect(abs(navigationEdge - rosterEdge) <= 0.5, "Navigation and roster fills share their leading edge")
        #expect(abs(rosterEdge - 13) <= 0.5, "The shared visual gutter stays 13pt")
        #expect(abs(try glyphCenter(around: 27) - glyphCenter(around: 70)) <= 0.5,
                "Independent symbol slots align their visible centres")
        let navigationTitle = try #require(firstTextInkX(image, around: 27, from: 40))
        let rosterTitle = try #require(firstTextInkX(image, around: 64, from: 40))
        #expect(abs(navigationTitle - rosterTitle) <= 0.5, "Navigation and unindented roster titles share a column")
        #expect(store.navigationAttempt == nil, "Inspecting the alignment never submits navigation")
    }

    @Test
    func selectedNavigationSurfaceHasEvenShellClearance() throws {
        let image = try render(NavigationHeader(browser: NavigationBrowser())
            .padding(.horizontal, Theme.Spacing.panelInset)
            .rosterBoundary(topInset: Theme.Spacing.navigationTopInset))
        let scale = CGFloat(image.pixelsWide) / Theme.Size.panelWidth
        let left = try #require((0..<Int(40 * scale)).first { x in
            alpha(image, x: CGFloat(x) / scale, y: 27) > 0.01
        })
        let top = try #require((0..<Int(30 * scale)).first { y in
            alpha(image, x: 60, y: CGFloat(y) / scale) > 0.01
        })
        #expect(abs(CGFloat(left - top) / scale) <= 0.5,
                "Visible navigation fill leaves equal space to the shell above and beside it")
        #expect(abs(CGFloat(left) / scale - 13) <= 0.5)

        let reference = try render(UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 8,
                                                         bottomTrailingRadius: 8, topTrailingRadius: 8,
                                                         style: .continuous)
            .fill(Theme.Colors.selection).frame(width: 80, height: 28)
            .padding(.leading, 13).padding(.top, 13)
            .frame(maxWidth: .infinity, alignment: .leading))
        for x in 14...21 {
            #expect(abs(alpha(image, x: CGFloat(x), y: 37) - alpha(reference, x: CGFloat(x), y: 37)) < 0.005,
                    "Internal corners stay rounded-control corners; only the shell-facing corner adapts")
        }
        for x in 14...23 {
            #expect(abs(alpha(image, x: CGFloat(x), y: 17) - alpha(reference, x: CGFloat(x), y: 17)) < 0.005,
                    "The top-leading corner still follows the shell inset")
        }
        #expect(alpha(image, x: 60, y: 12) < 0.01)
        #expect(alpha(image, x: 60, y: 14) > 0.01)
        #expect(alpha(image, x: 60, y: 40) > 0.01)
        #expect(alpha(image, x: 60, y: 42) < 0.01)
    }

    @Test
    func sourcesSelectionUsesRoundedControlCornersInsteadOfACapsule() throws {
        let browser = NavigationBrowser()
        let activity = try render(NavigationHeader(browser: browser))
        let scale = CGFloat(activity.pixelsWide) / Theme.Size.panelWidth
        let end = try #require((Int(20 * scale)..<Int(200 * scale)).first {
            alpha(activity, x: CGFloat($0) / scale, y: 19) < 0.01
        })
        browser.setMode(.all)
        let image = try render(NavigationHeader(browser: browser)
            .padding(.horizontal, Theme.Spacing.panelInset)
            .rosterBoundary(topInset: Theme.Spacing.navigationTopInset))
        let expectedStart = CGFloat(end) / scale + 4 + 13
        let start = try #require((Int((expectedStart - 2) * scale)..<Int((expectedStart + 3) * scale)).first {
            alpha(image, x: CGFloat($0) / scale, y: 27) > 0.01
        })
        let x = CGFloat(start) / scale
        let reference = try render(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.Colors.selection).frame(width: 80, height: 28)
            .padding(.leading, x).padding(.top, 13)
            .frame(maxWidth: .infinity, alignment: .leading))
        let matches = (1...10).allSatisfy { offset in
            [14, 15, 16, 17, 18, 19, 35, 36, 37, 38, 39, 40].allSatisfy { y in
                abs(alpha(image, x: x + CGFloat(offset), y: CGFloat(y))
                    - alpha(reference, x: x + CGFloat(offset), y: CGFloat(y))) < 0.005
            }
        }
        #expect(matches, "The compact Sources background follows the 8pt rounded-control reference, not 13pt pill corners")
    }

    @Test
    func viewChoiceTypographyMatchesRegularControlText() throws {
        let header = try render(NavigationHeader(browser: NavigationBrowser()))
        let textStart = Theme.Spacing.navigationContentInset + Theme.Size.navigationIcon + Theme.Spacing.navigationContentGap
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
            }.padding(.horizontal, Theme.Spacing.panelInset)
                .rosterBoundary(topInset: Theme.Spacing.navigationTopInset)
        )
        let rowLeft = try #require((0..<40).first { alpha(image, x: CGFloat($0), y: 65) > 0.01 })
        let titleColumn = CGFloat(rowLeft) + Theme.Spacing.navigationContentInset
            + Theme.Size.navigationIcon + Theme.Spacing.navigationContentGap
        let textLeft = try #require(firstTextInkX(image, around: 27, from: titleColumn))
        #expect(abs(textLeft - titleColumn) <= 2, "Short navigation labels use their own compact symbol slot")
        #expect((25..<39).contains { x in (17..<37).contains { y in
            alpha(image, x: CGFloat(x), y: CGFloat(y)) > 0.4
        } }, "The view's leading slot must contain a role glyph")
        #expect(abs(alpha(image, x: 22, y: 37) - alpha(image, x: 42, y: 37)) < 0.01,
                "No plate around the navigation glyph")
        #expect(alpha(image, x: 18, y: 27) > 0.01)
        #expect(abs(alpha(image, x: 18, y: 27) - alpha(image, x: 18, y: 65)) < 0.005,
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
                ForEach(0..<2) { index in
                    HoverRow(minHeight: rowHeight, verticalPadding: 0, isSelected: true,
                             accessibilityText: "row \(index)", action: {}) { _ in
                        Color.clear.frame(height: Theme.Size.rowIcon)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.panelInset)
            .rosterBoundary()
        )
        // 32pt bodies, 38pt headers and 40pt Quick rows share the real lower content boundary.
        #expect(alpha(image, x: Theme.Spacing.panelInset + 3, y: lastBottom - 4) < 0.01)
        #expect(alpha(image, x: Theme.Size.panelWidth - Theme.Spacing.panelInset - 3, y: lastBottom - 4) < 0.01)
        #expect(alpha(image, x: Theme.Spacing.panelInset + 14, y: lastBottom - 4) > 0.01)
        #expect(alpha(image, x: Theme.Spacing.panelInset + 4, y: lastTop + 4) > 0.01)
        #expect(alpha(image, x: Theme.Spacing.panelInset + 4, y: Theme.Spacing.panelInset + rowHeight - 4) > 0.01)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.panelInset).rosterBoundary())
                let centerY = Theme.Spacing.panelInset + 19
                #expect(abs(alpha(image, x: Theme.Spacing.panelInset + 9, y: centerY) - alpha(image, x: 210, y: centerY)) < 0.01)
                let ink = (21..<43).contains { x in
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
                .padding(.horizontal, Theme.Spacing.panelInset)
                .rosterBoundary()
        )

        // The first highlight is inset 13pt. Its top corner turns farther in than a
        // normal row, without also rounding its bottom into a capsule.
        #expect(alpha(image, x: 16, y: 16) < 0.01)
        #expect(alpha(image, x: Theme.Size.panelWidth - 16, y: 16) < 0.01)
        #expect(alpha(image, x: 27, y: 17) > 0.01)
        #expect(alpha(image, x: 17, y: 47) > 0.01)

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
