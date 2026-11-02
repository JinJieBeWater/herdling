import Foundation

struct CoreTerminalID: Hashable, Sendable {
    let coreID: String
    let terminalID: String
}

/// The address is local to the entry Core; identity belongs to the Core running the terminal.
struct CoreTerminalTarget: Equatable, Sendable {
    let id: CoreTerminalID
    let socketPath: String
    let entryCoreID: String
    let address: String
}
