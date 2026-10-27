import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct PanelSurfaceTests {
    @Test(arguments: [Theme.Radius.panel, Theme.Radius.agentActions], [ColorScheme.light, .dark])
    func panelsKeepAQuietAppearanceAwareGlassTint(cornerRadius: CGFloat, scheme: ColorScheme) throws {
        guard #available(macOS 26.0, *) else { return }
        let content = NSView()
        let glass = panelGlass(wrapping: content, cornerRadius: cornerRadius)
        #expect(glass.style == .regular)
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = glass.tintColor?.usingColorSpace(.sRGB) }
        let tint = try #require(resolved, "Long rosters quiet the backdrop through the glass itself, not a second surface")
        #expect(tint.alphaComponent > 0 && tint.alphaComponent <= 0.25, "The tint must leave the glass translucent")
        #expect(abs(tint.redComponent - tint.blueComponent) < 0.03
                && abs(tint.greenComponent - tint.blueComponent) < 0.03, "The tint is neutral, not another accent")
        #expect(scheme == .dark ? tint.redComponent < 0.25 : tint.redComponent > 0.9,
                "The glass follows the appearance instead of fixing a light or dark surface")
        #expect(glass.contentView === content)
        #expect(glass.cornerRadius == cornerRadius && glass.layer?.cornerRadius == cornerRadius)
        #expect(glass.layer?.cornerCurve == .continuous && glass.layer?.masksToBounds == true)
    }

    @Test
    func surfaceAddsNothingOverTheGlass() throws {
        guard #available(macOS 26.0, *) else { return }
        let hosting = NSHostingView(rootView: Color.clear.panelSurface())
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: 240)
        let window = MenuBarPanel()
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView = panelGlass(wrapping: hosting, cornerRadius: Theme.Radius.panel)
        window.orderBack(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(materialViews(in: hosting).isEmpty, "No second material under the glass")
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(center.alphaComponent < 0.01, "No scrim between the glass and the content")
    }

    @Test
    func glassKeepsMenuRefractionWithoutKeyFocus() async throws {
        guard #available(macOS 26.0, *) else { return }
        let window = MenuBarPanel()
        window.setContentSize(NSSize(width: Theme.Size.panelWidth, height: 240))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView = panelGlass(wrapping: NSView(), cornerRadius: Theme.Radius.panel)
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!window.isKeyWindow)
        let root = try #require(window.contentView?.superview?.layer)
        let filter = try #require(glassFilter(in: root), "Liquid Glass backdrop filter")
        let refraction = (filter.value(forKey: "inputRefractionOpacity") as? NSNumber)?.doubleValue ?? 0
        #expect(refraction > 0, "A native menu window refracts its backdrop even though it is not key")
    }

    private func glassFilter(in layer: CALayer) -> AnyObject? {
        filter(named: "glassBackground", in: layer)
    }

    @Test(arguments: ["textPrimary", "mutedTitle", "textSecondary", "textTertiary"], [ColorScheme.light, .dark])
    func panelInkTakesTheGlassVibrancy(token: String, scheme: ColorScheme) async throws {
        guard #available(macOS 26.0, *) else { return }
        let styles = ["textPrimary": Theme.Colors.textPrimary, "mutedTitle": Theme.Colors.mutedTitle,
                      "textSecondary": Theme.Colors.textSecondary, "textTertiary": Theme.Colors.textTertiary]
        let style = try #require(styles[token])
        let hosting = NSHostingView(rootView: Rectangle().fill(style).frame(width: 40, height: 10)
            .environment(\.colorScheme, scheme))
        let window = MenuBarPanel()
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 80, height: 40))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.contentView = panelGlass(wrapping: hosting, cornerRadius: Theme.Radius.panel)
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(filter(named: "vibrantColorMatrix", in: try #require(hosting.layer)) != nil,
                "\(token) must blend with the glass like a native menu label, not sit on it as fixed grey")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func quietStateFillsLiftTheGlassWithoutUsingTheAccent(scheme: ColorScheme) throws {
        func luminance(_ fill: AnyShapeStyle) throws -> CGFloat {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            // A mid-grey stand-in for the glass, so lifting and dimming both show.
            let hosting = NSHostingView(rootView: Rectangle().fill(fill).background(Color(white: 0.5))
                .frame(width: 10, height: 10).environment(\.colorScheme, scheme))
            hosting.appearance = appearance
            hosting.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.genericGray)).whiteComponent
        }
        let base = try luminance(Theme.Colors.noFill)
        let inspection = try luminance(Theme.Colors.inspection)
        let unavailable = try luminance(Theme.Colors.unavailableSelection)
        #expect(inspection > base, "Inspection adds light to the glass instead of greying it")
        #expect(unavailable > inspection, "An unavailable keyboard target stays distinct from brief inspection")
    }

    private func filter(named name: String, in layer: CALayer) -> AnyObject? {
        for filter in layer.filters ?? [] where (filter as AnyObject).value(forKey: "name") as? String == name {
            return filter as AnyObject
        }
        return layer.sublayers?.lazy.compactMap { filter(named: name, in: $0) }.first
    }

    private func materialViews(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap { materialViews(in: $0) }
    }
}
