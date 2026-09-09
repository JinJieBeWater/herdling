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
        dark: (1.00, 0.38, 0.54)
    )
    static let working = NSColor.controlAccentColor

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}
