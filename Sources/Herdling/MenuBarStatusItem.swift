import AppKit
import SwiftUI

@MainActor
final class MenuBarStatusItem: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onClick: (() -> Void)?
    private var lastStatus: MenuStatus?

    override init() {
        super.init()
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.title = ""
        button.image = nil
        button.toolTip = "Herdling"
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusWindowScaleChanged(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusWindowScaleChanged(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
    }

    func update(_ status: MenuStatus) {
        lastStatus = status
        let presentation = MenuBarStatusPresentation.for(status)
        let image = Self.summaryImage(
            presentation,
            scale: Self.renderingScale(
                buttonScale: item.button?.window?.backingScaleFactor,
                fallbackScale: NSScreen.main?.backingScaleFactor ?? 2
            )
        )
        item.length = ceil(image.size.width) + 10
        item.button?.image = image
        item.button?.title = ""
        item.button?.contentTintColor = nil
        item.button?.toolTip = presentation.accessibilityText
        item.button?.setAccessibilityLabel(presentation.accessibilityText)
    }

    func setHighlighted(_ highlighted: Bool) {
        item.button?.highlight(highlighted)
    }

    @objc private func clicked() {
        onClick?()
    }

    @objc private func statusWindowScaleChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === item.button?.window,
              let lastStatus
        else { return }
        update(lastStatus)
    }

    static func renderingScale(buttonScale: CGFloat?, fallbackScale: CGFloat) -> CGFloat {
        buttonScale ?? fallbackScale
    }

    private static func summaryImage(
        _ presentation: MenuBarStatusPresentation,
        scale: CGFloat
    ) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarSummaryStrip(entries: presentation.entries))
        renderer.scale = scale
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        image.accessibilityDescription = presentation.accessibilityText
        return image
    }
}

struct MenuBarStatusEntry: Equatable {
    let statusSymbol: String
    let count: Int?
}

struct MenuBarStatusPresentation: Equatable {
    let entries: [MenuBarStatusEntry]
    let accessibilityText: String

    static func `for`(_ status: MenuStatus) -> Self {
        switch status.availability {
        case .loading:
            return Self(
                entries: [MenuBarStatusEntry(statusSymbol: "ellipsis", count: nil)],
                accessibilityText: "Herdling, loading sessions"
            )
        case .offline:
            return Self(
                entries: [MenuBarStatusEntry(statusSymbol: "wifi.slash", count: nil)],
                accessibilityText: "Herdling, sources offline"
            )
        case .online:
            break
        }
        guard !status.counts.isEmpty else {
            return Self(
                entries: [MenuBarStatusEntry(statusSymbol: "circle.dotted", count: nil)],
                accessibilityText: "Herdling, no running agents"
            )
        }

        let entries = status.counts.map {
            MenuBarStatusEntry(statusSymbol: $0.status.indicatorSymbolName, count: $0.count)
        }
        let summary = status.counts.map {
            "\($0.count) \($0.status.menuBarLabel(count: $0.count))"
        }.joined(separator: ", ")
        return Self(entries: entries, accessibilityText: "Herdling, \(summary)")
    }
}

private struct MenuBarSummaryStrip: View {
    let entries: [MenuBarStatusEntry]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 2) {
                    Image(systemName: entry.statusSymbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 11, height: 13)
                    if let count = entry.count {
                        Text(count.formatted())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
            }
        }
        .foregroundStyle(.black)
        .fixedSize()
    }
}
