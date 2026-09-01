import AppKit
import SwiftUI

enum HerdrBrand {
    private static let rawMark: NSImage = {
        let sourceTreeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/herdr-mark.svg")
        let image = [Bundle.main.url(forResource: "herdr-mark", withExtension: "svg"), sourceTreeURL]
            .compactMap { $0 }
            .compactMap(NSImage.init(contentsOf:))
            .first
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Herdr")
            ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = "Herdr"
        return image
    }()

    @MainActor
    static let applicationIcon: NSImage = {
        let renderer = ImageRenderer(content:
            ZStack {
                Color(nsColor: NSColor(srgbRed: 0.851, green: 0.855, blue: 0.847, alpha: 1))
                Image(nsImage: rawMark)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color(nsColor: NSColor(srgbRed: 0.188, green: 0.204, blue: 0.220, alpha: 1)))
            }
            .frame(width: 512, height: 512)
        )
        renderer.scale = 1
        return renderer.nsImage ?? rawMark
    }()
}
