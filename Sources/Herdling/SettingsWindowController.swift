import AppKit
import SwiftUI

/// Settings' own window.
///
/// It keeps the system titlebar band — AppKit draws it, so a grouped `Form` scrolls under it the way
/// a pane does in System Settings — and a lifecycle of its own: closing it never touches the panel.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(store: SessionStore) {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Theme.Size.settingsWidth,
                height: Theme.Size.settingsHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Herdling Settings"
        // The content still runs under the bar, but a hairline would split the surface it unifies.
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = false
        // Stock Settings is dragged by its titlebar, never by its content.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))

        super.init(window: window)

        if !window.setFrameAutosaveName("Settings Window") {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Herdling is an accessory app, so a window only comes forward when the app is activated.
    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
