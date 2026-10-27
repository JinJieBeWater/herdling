import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized) @MainActor
struct PanelSymbolTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func disclosureRemainsLegibleWithoutASelectedSourcePlate(scheme: ColorScheme) throws {
        for highlighted in [false, true] {
            let prominence: BackgroundProminence = highlighted ? .increased : .standard
            let actual = try render(DisclosureChevron(isExpanded: false)
                .environment(\.backgroundProminence, prominence), scheme: scheme)
            let expected = try render(Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(highlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 12).environment(\.backgroundProminence, prominence), scheme: scheme)
            let difference = (0..<actual.pixelsWide).reduce(CGFloat.zero) { total, x in
                total + (0..<actual.pixelsHigh).reduce(CGFloat.zero) {
                    $0 + abs((actual.colorAt(x: x, y: $1)?.alphaComponent ?? 0) - (expected.colorAt(x: x, y: $1)?.alphaComponent ?? 0))
                }
            }
            #expect(difference < 1, "Disclosure uses secondary ink at rest, white primary ink on the menu highlight")
        }
    }

    @Test
    func listSymbolsMatchTheLightReferenceWithoutChangingTheirSlot() throws {
        for name in ["desktopcomputer", "network", "circle", "xmark.circle.fill", "gearshape"] {
            let configured = try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)))
            let expected = try render(Image(nsImage: configured).renderingMode(.template)
                .foregroundStyle(.black).frame(width: 22, height: 22))
            let actual = try render(RowSymbol(symbol: name, tint: .black))
            let a = try inkBounds(actual), b = try inkBounds(expected)
            #expect(abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1,
                    "\(name) must have the reference's 14pt Regular silhouette, not the old small bold mark")
            #expect(abs(a.midX - b.midX) <= 0.5 && abs(a.midY - b.midY) <= 0.5,
                    "Changing the glyph must keep it centred in its transparent slot")
        }
    }

    @Test
    func sourceKindUsesNeutralInkInsteadOfDecorativeBlueAndPurple() throws {
        for source in PreviewFixtures.makeStore().sources {
            let actual = try render(RowSymbol(symbol: source.rosterSymbol, tint: source.rosterTint))
            var count = 0
            var mostChromatic: CGFloat = 0
            for x in 0..<actual.pixelsWide {
                for y in 0..<actual.pixelsHigh {
                    guard let color = actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.25 else { continue }
                    count += 1
                    mostChromatic = max(mostChromatic,
                        max(color.redComponent, color.greenComponent, color.blueComponent) -
                        min(color.redComponent, color.greenComponent, color.blueComponent))
                }
            }
            #expect(count > 30, "Source type must remain visible")
            #expect(mostChromatic < 0.03, "\(source.id) is a structural role, not a status accent")
        }
    }

    @Test
    func navigationGlyphUsesTheReferenceControlWeight() throws {
        let configured = try #require(NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
        let expected = try render(Image(nsImage: configured).renderingMode(.template)
            .foregroundStyle(.black).frame(width: 14, height: 14))
        let actual = try render(NavigationHeader(browser: NavigationBrowser()), width: 420)
        func ink(_ image: NSBitmapImageRep, width: CGFloat, rect: CGRect, full: CGFloat = 1) -> Int {
            let scale = CGFloat(image.pixelsWide) / width
            return (Int(rect.minX * scale)..<Int(rect.maxX * scale)).reduce(0) { count, x in
                count + (Int(rect.minY * scale)..<Int(rect.maxY * scale)).filter {
                    (image.colorAt(x: x, y: $0)?.alphaComponent ?? 0) / full > 0.5
                }.count
            }
        }
        // Measure against the glyph's own ink rather than opaque black.
        let scale = CGFloat(actual.pixelsWide) / 420
        let inset = Theme.Spacing.navigationVisualInset
        let glyph = CGRect(x: inset + 5, y: 7, width: 20, height: 30)
        let full = (Int(glyph.minX * scale)..<Int(glyph.maxX * scale)).flatMap { x in
            (Int(glyph.minY * scale)..<Int(glyph.maxY * scale)).map { actual.colorAt(x: x, y: $0)?.alphaComponent ?? 0 }
        }.max() ?? 1
        let a = ink(actual, width: 420, rect: glyph, full: full)
        let b = ink(expected, width: 44, rect: CGRect(x: 0, y: 0, width: 44, height: 44))
        #expect(b > 30)
        #expect(abs(a - b) <= 3, "Navigation controls use Medium rather than list Regular: \(a) vs \(b) ink pixels")
    }

    @Test
    func buttonVariantCannotTurnAnIdleOutlineIntoAFilledState() throws {
        let base = RowSymbol(symbol: "circle", tint: .black)
        let normal = try render(Button(action: {}) { base }.buttonStyle(.plain))
        let inherited = try render(Button(action: {}) { base }.buttonStyle(.plain).symbolVariant(.fill))
        var difference: CGFloat = 0
        for x in 0..<normal.pixelsWide {
            for y in 0..<normal.pixelsHigh {
                difference += abs((normal.colorAt(x: x, y: y)?.alphaComponent ?? 0) -
                                  (inherited.colorAt(x: x, y: y)?.alphaComponent ?? 0))
            }
        }
        #expect(difference < 1, "Only the explicit status symbol may choose its filled variant")
    }

    private func render(_ view: some View, width: CGFloat = 44, scheme: ColorScheme = .light) throws -> NSBitmapImageRep {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { app.appearance = previous }
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 44).environment(\.colorScheme, scheme))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 44)
        let window = NSWindow(contentRect: hosting.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func inkBounds(_ image: NSBitmapImageRep) throws -> CGRect {
        let points = (0..<image.pixelsWide).flatMap { x in
            (0..<image.pixelsHigh).compactMap { y -> CGPoint? in
                guard (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 else { return nil }
                return CGPoint(x: x, y: y)
            }
        }
        let scale = CGFloat(image.pixelsWide) / 44
        return CGRect(x: try #require(points.map(\.x).min()) / scale,
                      y: try #require(points.map(\.y).min()) / scale,
                      width: (try #require(points.map(\.x).max()) - #require(points.map(\.x).min()) + 1) / scale,
                      height: (try #require(points.map(\.y).max()) - #require(points.map(\.y).min()) + 1) / scale)
    }
}
