enum TerminalApplication: String, CaseIterable, Sendable {
    case ghostty
    case kero

    var name: String {
        switch self {
        case .ghostty: "Ghostty"
        case .kero: "Kero"
        }
    }
}
