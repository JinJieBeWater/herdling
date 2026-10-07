import KeyboardShortcuts

/// One optional user shortcut, shared by Settings and the panel controller.
/// Register replaces the previous key-up action; unregister preserves the saved combination.
@MainActor
enum PanelShortcut {
    static let name = KeyboardShortcuts.Name("togglePanel")
    private static let registration = PanelShortcutRegistration(name: name)

    static func register(_ action: @escaping @MainActor () -> Void) {
        registration.register(action)
    }

    static func unregister() {
        registration.unregister()
    }
}

/// The global-hotkey boundary is injectable so tests never assign a system shortcut.
@MainActor
final class PanelShortcutRegistration {
    private let name: KeyboardShortcuts.Name
    private let onKeyUp: (KeyboardShortcuts.Name, @escaping @MainActor () -> Void) -> Void
    private let removeHandler: (KeyboardShortcuts.Name) -> Void

    init(
        name: KeyboardShortcuts.Name,
        onKeyUp: @escaping (KeyboardShortcuts.Name, @escaping @MainActor () -> Void) -> Void = { name, action in
            KeyboardShortcuts.onKeyUp(for: name) { action() }
        },
        removeHandler: @escaping (KeyboardShortcuts.Name) -> Void = {
            KeyboardShortcuts.removeHandler(for: $0)
        }
    ) {
        self.name = name
        self.onKeyUp = onKeyUp
        self.removeHandler = removeHandler
    }

    func register(_ action: @escaping @MainActor () -> Void) {
        removeHandler(name)
        onKeyUp(name, action)
    }

    func unregister() {
        removeHandler(name)
    }
}
