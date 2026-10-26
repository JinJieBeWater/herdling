import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized)
@MainActor
struct PanelSurfaceTests {
    @Test(arguments: [Theme.Radius.panel, Theme.Radius.agentActions])
    func panelsUseUntintedLiquidGlassLikeNativeMenus(cornerRadius: CGFloat) throws {
        guard #available(macOS 26.0, *) else { return }
        let content = NSView()
        let glass = panelGlass(wrapping: content, cornerRadius: cornerRadius)
        #expect(glass.style == .regular)
        #expect(glass.tintColor == nil, "A tint over the glass flattens it compared with a native menu")
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
        for filter in layer.filters ?? [] where (filter as AnyObject).value(forKey: "name") as? String == "glassBackground" {
            return filter as AnyObject
        }
        return layer.sublayers?.lazy.compactMap { glassFilter(in: $0) }.first
    }

    private func materialViews(in view: NSView) -> [NSVisualEffectView] {
        (view as? NSVisualEffectView).map { [$0] } ?? view.subviews.flatMap { materialViews(in: $0) }
    }
}
