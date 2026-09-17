import AppKit
import SwiftUI

extension AgentStatus {
    var indicatorSymbolName: String {
        switch self {
        case .blocked: "xmark.circle.fill"
        case .working: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Vivid badge fill for states that need attention; nil keeps the neutral low-key badge.
    var badgeTint: Color? {
        switch self {
        case .blocked, .working: color
        case .done, .idle, .unknown: nil
        }
    }

    var rosterLabel: String {
        switch self {
        case .blocked: "needs you"
        case .done: "done"
        case .working: "working"
        case .idle: "ready"
        case .unknown: "unknown"
        }
    }

    func menuBarLabel(count: Int) -> String {
        let agent = count == 1 ? "agent" : "agents"
        return switch self {
        case .blocked: "blocked \(agent)"
        case .working: "working \(agent)"
        case .done: "completed \(agent)"
        case .idle: "idle \(agent)"
        case .unknown: "unknown \(agent)"
        }
    }

    var color: Color {
        switch self {
        case .blocked: Color(nsColor: StatusPalette.blocked)
        case .working: Color(nsColor: StatusPalette.working)
        case .done, .idle, .unknown: .secondary
        }
    }
}

enum StatusPalette {
    static let blocked = adaptive(
        light: (0.62, 0.08, 0.24),
        dark: (1.00, 0.38, 0.54),
        highContrastLight: (0.48, 0.00, 0.16),
        highContrastDark: (1.00, 0.62, 0.72)
    )
    static let working = NSColor.controlAccentColor

    /// Custom colours need a variant per appearance including the increased-contrast ones, per the
    /// HIG colour guidance. The flag comes from `NSWorkspace`, not from matching appearance names:
    /// on macOS 27 an appearance built from `.accessibilityHighContrastAqua` reports its name as
    /// `.aqua`, so name matching cannot see the setting.
    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        highContrastLight: (CGFloat, CGFloat, CGFloat),
        highContrastDark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let rgb = isDark
                ? (increased ? highContrastDark : dark)
                : (increased ? highContrastLight : light)
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}
