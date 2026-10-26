import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct RosterScrollbarTests {
    @Test
    func overflowingRosterUsesThinOverlayWithoutLosingContentWidth() throws {
        let hosted = host()
        defer { hosted.window.close() }
        let scroll = try #require(findScrollView(hosted.view))
        let scroller = try #require(scroll.verticalScroller)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroller.scrollerStyle == .overlay, "Replacement must opt into native overlay fading too")
        #expect(scroll.hasVerticalScroller, "Overflowing content needs a managed native overlay")
        #expect(scroll.contentView.bounds.width == 420, "Viewport spans the panel; rows keep their own symmetric 13pt inset")
        #expect(scroll.documentView!.bounds.height > scroll.contentView.bounds.height)
        let knob = scroller.rect(for: .knob)
        #expect(knob.width == 6, "Scrolling thumb must use Tinycast's 6pt surface, not the native broad knob")
        #expect(knob.height >= 28)
        #expect(hosted.store.navigationAttempt == nil)
    }

    @Test
    func hoveredThumbStaysQuietAndDoesNotCoverTheRowDisclosureColumn() throws {
        let hosted = host()
        defer { hosted.window.close() }
        let scroll = try #require(findScrollView(hosted.view))
        let scroller = try #require(scroll.verticalScroller)
        scroller.knobStyle = .light
        try hover(scroller, window: hosted.window)
        settle(hosted.view)
        let knob = scroller.rect(for: .knob)
        let column = scroller.convert(knob, to: scroll)
        #expect(knob.width <= 10)
        // Trailing glyph ink ends about 15pt inside a roster row; keep the rail outside it.
        #expect(column.minX >= scroll.bounds.maxX - 13)
        let maxAlpha = try paintedAlpha(scroller)
        #expect(maxAlpha > 0.1 && maxAlpha <= 0.43,
                "Hovered thumb uses the quiet 0.42 ink, not an opaque white native capsule")
    }

    @Test
    func hoveredTrackAddsNoBackgroundBesideTheFullWidthRows() throws {
        let hosted = host()
        defer { hosted.window.close() }
        let scroller = try #require(findScrollView(hosted.view)?.verticalScroller)
        try hover(scroller, window: hosted.window)
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(scroller.bounds.width * 2), pixelsHigh: Int(scroller.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        NSGraphicsContext.current?.cgContext.scaleBy(x: 2, y: 2)
        scroller.drawKnobSlot(in: scroller.rect(for: .knobSlot), highlight: true)
        NSGraphicsContext.restoreGraphicsState()
        let maxAlpha = (0..<image.pixelsWide).flatMap { x in
            (0..<image.pixelsHigh).map { image.colorAt(x: x, y: $0)!.alphaComponent }
        }.max() ?? 0
        #expect(maxAlpha == 0, "Only the thumb may paint; hover cannot introduce a competing full track")
        #expect(scroller.target === findScrollView(hosted.view))
    }

    @Test
    func sourceDisclosureInkStaysOutsideTheNativeScrollHitArea() throws {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApplication.shared.appearance = previous }
        let hosted = host(mode: .all)
        defer { hosted.window.close() }
        let scroll = try #require(findScrollView(hosted.view))
        let scroller = try #require(scroll.verticalScroller)
        let edge = scroller.convert(scroller.bounds, to: hosted.view).minX
        let image = try #require(hosted.view.bitmapImageRepForCachingDisplay(in: hosted.view.bounds))
        hosted.view.cacheDisplay(in: hosted.view.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / 420
        let points = (Int(382 * scale)..<Int(410 * scale)).flatMap { x in
            (Int(65 * scale)..<Int(75 * scale)).compactMap { y -> CGFloat? in
                guard let color = image.colorAt(x: x, y: y), color.alphaComponent > 0.3,
                      min(color.redComponent, color.greenComponent, color.blueComponent) > 0.3 else { return nil }
                return CGFloat(x) / scale
            }
        }
        let lastInk = try #require(points.max(), "Source chevron must be present in the real rendered header")
        #expect(lastInk < edge, "The glyph must stay outside both the visible rail and its native hit area")
    }

    @Test
    func fullWidthSourceSurfaceAndKeyboardOutlineStayBesideFixedWidthThumb() throws {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        defer { NSApplication.shared.appearance = previous }
        let hosted = host(mode: .all)
        defer { hosted.window.close() }
        let scroller = try #require(findScrollView(hosted.view)?.verticalScroller)
        func snapshot() throws -> NSBitmapImageRep {
            scroller.isHidden = true
            let image = try #require(hosted.view.bitmapImageRepForCachingDisplay(in: hosted.view.bounds))
            hosted.view.cacheDisplay(in: hosted.view.bounds, to: image)
            return image
        }
        func alpha(_ image: NSBitmapImageRep, _ x: CGFloat) -> CGFloat {
            let scale = CGFloat(image.pixelsWide) / 420
            return image.colorAt(x: Int(x * scale), y: Int(69 * scale))!.alphaComponent
        }
        let ordinary = try snapshot()
        #expect(alpha(ordinary, 406) > alpha(ordinary, 417) + 0.03,
                "Ordinary source highlight must keep the full right edge, not a permanent empty lane")
        #expect(abs(alpha(ordinary, 14) - alpha(ordinary, 406)) < 0.01,
                "Source surface must keep symmetric 13pt content boundaries")
        let normal = scroller.convert(scroller.rect(for: .knob), to: hosted.view)
        #expect(normal.width == 6)
        #expect(normal.minX >= 413 && normal.maxX <= 419,
                "Painted thumb belongs outside the row, in the existing right margin")
        try hover(scroller, window: hosted.window)
        let hovered = scroller.convert(scroller.rect(for: .knob), to: hosted.view)
        #expect(hovered.minX == normal.minX && hovered.width == normal.width,
                "Hover must change ink, not expand toward the source rounded edge")
        #expect(abs(alpha(try snapshot(), 406) - alpha(ordinary, 406)) < 0.01)
        hosted.browser.moveSelection(by: 1)
        settle(hosted.view)
        #expect(hosted.browser.selection == .source("local"))
        let keyboard = try snapshot()
        #expect(alpha(keyboard, 406) > alpha(ordinary, 406), "Keyboard outline must reach the same full row edge")
        #expect(abs(alpha(keyboard, hovered.midX) - alpha(ordinary, 417)) < 0.01,
                "Under the thumb, only the panel scrim may remain—not source wash or keyboard outline")
        #expect(hosted.store.navigationAttempt == nil)
    }

    @Test
    func wheelAndKeyboardSelectionStillScrollTheNativeViewport() throws {
        let hosted = host()
        defer { hosted.window.close() }
        let scroll = try #require(findScrollView(hosted.view))
        let scroller = try #require(scroll.verticalScroller)
        #expect(scroller.target === scroll, "NSScrollView must still own native scroller actions")
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: -100, wheel2: 0, wheel3: 0))
        scroller.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        settle(hosted.view)
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(scroller.doubleValue > 0)
        // Programmatic scrolling must keep geometry at each end, not detach the replacement.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.documentView!.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroller.doubleValue == 1)
        let end = scroller.rect(for: .knob)
        #expect(abs((scroller.isFlipped ? end.maxY : end.minY) -
                    (scroller.isFlipped ? scroller.bounds.maxY - 8 : 8)) < 0.01)
        let ids = hosted.browser.quickIDs
        hosted.browser.moveSelection(by: 1)
        settle(hosted.view)
        #expect(scroll.contentView.bounds.minY < 50, "Keyboard scrollTo must bring the first target back")
        #expect(hosted.browser.quickIDs == ids)
        #expect(hosted.store.navigationAttempt == nil)
    }

    @Test
    func systemScrollerStyleChangeCannotBringBackALegacyGutter() async throws {
        let hosted = host()
        defer { hosted.window.close() }
        let scroll = try #require(findScrollView(hosted.view))
        scroll.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        // Reinstallation runs after AppKit's notification handlers, on the next main-queue turn.
        try await Task.sleep(for: .milliseconds(80))
        settle(hosted.view)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.contentView.bounds.width == 420)
        #expect(scroll.verticalScroller is RosterScroller)
    }

    @Test
    func shortListHasNoScrollableThumb() throws {
        let hosted = host(count: 0)
        defer { hosted.window.close() }
        let scroll = try #require(findScrollView(hosted.view))
        #expect(scroll.documentView!.bounds.height <= scroll.contentView.bounds.height)
        if let scroller = scroll.verticalScroller {
            #expect(scroller.rect(for: .knob).isEmpty)
        }
    }

    @Test
    func nonScrollableRosterDrawsNeitherThumbNorHoveredRail() throws {
        let hosted = host(count: 0)
        defer { hosted.window.close() }
        let scroller = try #require(findScrollView(hosted.view)?.verticalScroller)
        try hover(scroller, window: hosted.window)
        #expect(try paintedAlpha(scroller, includingRail: true) == 0,
                "A short roster must stay quiet even when the pointer enters its edge")
    }

    @Test
    func disabledScrollerDrawsNoRailWhileItsOldFrameStillExists() throws {
        let hosted = host()
        defer { hosted.window.close() }
        let scroller = try #require(findScrollView(hosted.view)?.verticalScroller)
        try hover(scroller, window: hosted.window)
        scroller.isEnabled = false
        #expect(try paintedAlpha(scroller, includingRail: true) == 0)
    }

    private func hover(_ scroller: NSScroller, window: NSWindow) throws {
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered,
            location: scroller.convert(CGPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        scroller.mouseEntered(with: event)
    }

    private func paintedAlpha(_ scroller: NSScroller, includingRail: Bool = false) throws -> CGFloat {
        if scroller.bounds.isEmpty { return 0 }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(scroller.bounds.width * 2), pixelsHigh: Int(scroller.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.scaleBy(x: 2, y: 2)
        scroller.drawKnob()
        if includingRail { scroller.drawKnobSlot(in: scroller.rect(for: .knobSlot), highlight: false) }
        NSGraphicsContext.restoreGraphicsState()
        return (0..<bitmap.pixelsWide).flatMap { x in
            (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: x, y: $0)?.alphaComponent }
        }.max() ?? 0
    }

    private func host(count: Int = 30, mode: NavigationBrowser.Mode = .quick) -> (view: NSHostingView<AnyView>, window: NSWindow, store: SessionStore, browser: NavigationBrowser) {
        let store = PreviewFixtures.makeStore()
        let agents = (0..<count).map { index in
            AgentInfo(paneID: "scroll-pane-\(index)", title: "Scroll fixture \(index)", status: .working,
                      workspace: "fixture", cwd: "/fixture", updatedAt: .now)
        }
        let browser = NavigationBrowser(sources: [SourceInfo(descriptor: .local,
            sessions: [SessionInfo(name: "default", agents: agents, online: true)], online: true)])
        browser.setMode(mode)
        if mode == .all { browser.toggleSource("local") }
        let view = NSHostingView(rootView: AnyView(AgentListView(store: store, browser: browser).environment(\.colorScheme, .dark)))
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 240)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        settle(view)
        return (view, window, store, browser)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        view.layoutSubtreeIfNeeded()
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { findScrollView($0) }.first
    }
}
