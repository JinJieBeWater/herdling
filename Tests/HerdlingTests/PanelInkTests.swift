import AppKit
import SwiftUI
import Testing
@testable import Herdling

@Suite(.serialized) @MainActor
struct PanelInkTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func warningInkHasContrastOnReferenceSurfaces(scheme: ColorScheme, increasedContrast: Bool) throws {
        let image = try render(Rectangle().fill(Theme.Colors.warning), scheme: scheme, increasedContrast: increasedContrast)
        let ink = try #require(image.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        for background: CGFloat in scheme == .dark ? [0, 0.2] : [0.9, 1] {
            let ratio = (max(luminance(ink), linear(background)) + 0.05)
                / (min(luminance(ink), linear(background)) + 0.05)
            #expect(ratio >= 4.5, "Warning ink must stay distinct from decorative Settings orange on reference surfaces: \(ratio)")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func workingGlyphKeepsContrastOnActualMenuBackdrops(scheme: ColorScheme) throws {
        let backgrounds: [NSColor] = scheme == .light
            ? [.white, NSColor(srgbRed: 117 / 255, green: 138 / 255, blue: 175 / 255, alpha: 1)]
            : [.black, NSColor(white: 0.2, alpha: 1)]
        for background in backgrounds {
            let image = try render(
                RowSymbol(symbol: AgentStatus.working.indicatorSymbolName, tint: AgentStatus.working.badgeTint)
                    .frame(width: 40, height: 40).background(Color(nsColor: background)),
                scheme: scheme
            )
            let scale = CGFloat(image.pixelsWide) / 40
            let glyphInk = (Int(9 * scale)..<Int(31 * scale)).flatMap { x in
                (Int(9 * scale)..<Int(31 * scale)).compactMap { y in
                    image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                }
            }
            let ink = try #require(glyphInk.max {
                $0.blueComponent - $0.redComponent < $1.blueComponent - $1.redComponent
            })
            let surface = try #require(image.colorAt(x: Int(37 * scale), y: Int(20 * scale))?.usingColorSpace(.sRGB))
            let ratio = (max(luminance(ink), luminance(surface)) + 0.05)
                / (min(luminance(ink), luminance(surface)) + 0.05)
            #expect(ratio >= 3, "The working glyph must remain distinct from the menu backdrop: \(ratio)")
            #expect(ink.blueComponent > ink.redComponent, "Working keeps its blue state identity")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func highlightedSecondaryTextKeepsSmallTextContrast(scheme: ColorScheme) throws {
        let image = try render(HStack(spacing: 0) {
            Rectangle().fill(Theme.Colors.textSecondary).background(Theme.Colors.highlight)
            Rectangle().fill(Theme.Colors.highlight)
        }.environment(\.backgroundProminence, .increased), scheme: scheme)
        let scale = CGFloat(image.pixelsWide) / 40
        let ink = try #require(image.colorAt(x: Int(5 * scale), y: Int(20 * scale))?.usingColorSpace(.sRGB))
        let surface = try #require(image.colorAt(x: Int(35 * scale), y: Int(20 * scale))?.usingColorSpace(.sRGB))
        let ratio = (max(luminance(ink), luminance(surface)) + 0.05)
            / (min(luminance(ink), luminance(surface)) + 0.05)
        #expect(ratio >= 4.5, "Highlighted subtitles must remain readable, not fade into the selection: \(ratio)")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func ordinaryInkKeepsItsHierarchy(scheme: ColorScheme) throws {
        var alphas: [CGFloat] = []
        for style in [Theme.Colors.textPrimary, Theme.Colors.textSecondary, Theme.Colors.textTertiary] {
            let image = try render(Rectangle().fill(style), scheme: scheme)
            alphas.append(try #require(image.colorAt(x: 5, y: 5)).alphaComponent)
        }
        #expect(alphas[0] > alphas[1] && alphas[1] > alphas[2], "Primary > secondary > tertiary")
    }

    private func linear(_ value: CGFloat) -> CGFloat {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func render(_ view: some View, scheme: ColorScheme,
                        increasedContrast: Bool = false) throws -> NSBitmapImageRep {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = NSAppearance(named: scheme == .dark
            ? (increasedContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
            : (increasedContrast ? .accessibilityHighContrastAqua : .aqua))
        defer { app.appearance = previous }
        let hosting = NSHostingView(rootView: view.frame(width: 40, height: 40).environment(\.colorScheme, scheme))
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        hosting.appearance = app.appearance
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
