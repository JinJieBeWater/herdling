import AppKit
import Observation
import SwiftUI

extension EnvironmentValues {
    @Entry var showAgentActions: (@MainActor (NavigationDestination, AgentActionsAnchor) -> Void)? = nil
}

@MainActor
final class AgentActionsAnchor {
    weak var view: NSView?

    var frame: NSRect? {
        guard let view, !view.isHiddenOrHasHiddenAncestor,
              let window = view.window, window.isVisible else { return nil }
        // SwiftUI bridges can expose the whole viewport as visibleRect, beyond the row's bounds.
        let visible = view.bounds.intersection(view.visibleRect)
        guard !visible.isEmpty else { return nil }
        return window.convertToScreen(view.convert(visible, to: nil))
    }
}

extension View {
    func agentActions(_ destination: NavigationDestination?) -> some View {
        modifier(AgentContextAction(destination: destination))
    }
}

private struct AgentContextAction: ViewModifier {
    let destination: NavigationDestination?
    @Environment(\.showAgentActions) private var show
    @State private var anchor = AgentActionsAnchor()

    func body(content: Content) -> some View {
        if let destination, destination.agentFocusID != nil, let show {
            content
                .overlay { AgentContextClick(anchor: anchor, action: { show(destination, anchor) }) }
                .accessibilityAction(named: Text("Actions")) { show(destination, anchor) }
        } else {
            content
        }
    }
}

/// Transparent to normal clicks, hover and scrolling. No extra row control or hit column.
struct AgentContextClick: NSViewRepresentable {
    let anchor: AgentActionsAnchor
    let action: () -> Void
    func makeNSView(context: Context) -> ContextClickView { ContextClickView() }
    func updateNSView(_ view: ContextClickView, context: Context) {
        view.action = action
        anchor.view = view
    }

    final class ContextClickView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                || ((event.type == .leftMouseDown || event.type == .leftMouseUp) && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) { action?() }
        override func rightMouseUp(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
        override func isAccessibilityElement() -> Bool { false }
    }
}

/// Agent-only supplementary actions, in a child window independent of roster layout.
@MainActor
final class AgentActionsMenuController {
    private let parent: MenuBarPanel
    private let store: SessionStore
    private let browser: NavigationBrowser
    private let panel = MenuBarPanel()
    private let selection = AgentActionSelection()
    private var destination: NavigationDestination?
    private var anchor: AgentActionsAnchor?
    private var monitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var openingPointer = NSPoint.zero
    private var pointerArmed = false
    private var keyboardInput = false

    init(parent: MenuBarPanel, store: SessionStore, browser: NavigationBrowser) {
        self.parent = parent
        self.store = store
        self.browser = browser
        panel.title = "Agent actions"
    }

    var isPresented: Bool { destination != nil && panel.isVisible }

    func present(for destination: NavigationDestination, anchor: AgentActionsAnchor) {
        guard parent.isVisible, anchor.view?.window === parent, let row = anchor.frame,
              browser.selectForInspection(destination) else { return }
        dismiss(returnFocus: false)
        browser.beginInspection()
        keyboardInput = false
        self.destination = destination
        self.anchor = anchor
        let presentation = browser.presentation(for: destination)
        panel.title = "Actions: \(presentation.title) — \(presentation.subtitle)"
        selection.action = canOpen ? .open : .observe
        openingPointer = NSEvent.mouseLocation
        pointerArmed = false
        panel.appearance = parent.appearance
        let width = Self.frame(parent: parent.frame, row: row,
                               contentSize: NSSize(width: Theme.Size.agentActionsWidth, height: 1),
                               visibleFrame: visibleFrame).width
        let hosting = NSHostingView(rootView: AgentActionsMenuContent(
            store: store, browser: browser, destination: destination, selection: selection, width: width,
            perform: { [weak self] in self?.perform($0) },
            hover: { [weak self] action in
                guard let self, self.pointerArmed, action != .open || self.canOpen else { return }
                self.selection.action = action
            }
        ))
        if #available(macOS 26.0, *) {
            panel.contentView = panelGlass(wrapping: hosting, cornerRadius: Theme.Radius.agentActions)
        } else {
            panel.contentView = hosting
        }
        panel.setFrame(Self.frame(parent: parent.frame, row: row, contentSize: hosting.fittingSize, visibleFrame: visibleFrame), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) == true }
            return consumed ? nil : event
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(returnFocus: false) }
        }
        if let clip = anchor.view?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }
    }

    func dismiss(returnFocus: Bool = true) {
        let wasPresented = isPresented
        destination = nil
        anchor = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        if wasPresented {
            browser.holdPointer(at: NSEvent.mouseLocation)
            browser.endInspection(keyboard: keyboardInput)
        }
        if wasPresented, returnFocus, parent.isVisible { parent.makeKey() }
    }

    func reposition() {
        guard isPresented else { return }
        guard let row = anchor?.frame else { keyboardInput = false; dismiss(); return }
        panel.setFrame(Self.frame(parent: parent.frame, row: row, contentSize: panel.frame.size, visibleFrame: visibleFrame), display: true)
        if !canOpen, selection.action == .open { selection.action = .observe }
    }

    /// Called before the roster's key handler as well as by the child window's event monitor.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isPresented, event.window === parent || event.window === panel,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        pointerArmed = false
        openingPointer = NSEvent.mouseLocation
        switch event.keyCode {
        case 53: dismiss()
        case 125, 126:
            keyboardInput = true
            selection.action = selection.action == .open || !canOpen ? .observe : .open
        case 36, 76, 49: perform(selection.action, keyboard: true)
        default: return false
        }
        return true
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        switch event.type {
        case .keyDown: return handleKeyDown(event)
        case .mouseMoved:
            if NSEvent.mouseLocation != openingPointer { pointerArmed = true }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.window === parent {
                keyboardInput = false
                dismiss()
                return true // This gesture closes the menu; it never opens the row underneath.
            }
        default: break
        }
        return false
    }

    private var visibleFrame: NSRect { (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame }
    private var canOpen: Bool {
        guard let destination else { return false }
        return browser.isAvailable(destination) && !(browser.attempt?.destination == destination && browser.attempt?.phase == .pending)
    }

    private func perform(_ action: AgentMenuAction, keyboard: Bool = false) {
        guard let destination, action != .open || canOpen else { return }
        keyboardInput = keyboard
        dismiss()
        switch action {
        case .open: store.navigate(to: destination)
        case .observe: store.setObserveOnly(!store.isObserveOnly(destination), for: destination)
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    static func frame(parent: NSRect, row: NSRect, contentSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let inset = Theme.Spacing.panelInset
        let width = min(contentSize.width, max(1, parent.width - inset * 2), max(1, visibleFrame.width - inset * 2))
        let height = min(contentSize.height, max(1, visibleFrame.height - inset * 2))
        let below = row.minY - Theme.Spacing.xs - height
        let y = below >= visibleFrame.minY + inset ? below : row.maxY + Theme.Spacing.xs
        return NSRect(
            x: min(max(row.maxX - width, visibleFrame.minX + inset), visibleFrame.maxX - inset - width),
            y: min(max(y, visibleFrame.minY + inset), visibleFrame.maxY - inset - height),
            width: width, height: height
        )
    }
}

private enum AgentMenuAction { case open, observe }

@Observable @MainActor
private final class AgentActionSelection { var action = AgentMenuAction.open }

private struct AgentActionsMenuContent: View {
    let store: SessionStore
    let browser: NavigationBrowser
    let destination: NavigationDestination
    let selection: AgentActionSelection
    let width: CGFloat
    let perform: (AgentMenuAction) -> Void
    let hover: (AgentMenuAction) -> Void

    private var pending: Bool { browser.attempt?.destination == destination && browser.attempt?.phase == .pending }
    private var available: Bool { browser.isAvailable(destination) }

    var body: some View {
        VStack(spacing: 0) {
            row(.open, title: pending ? "Opening…" : available ? "Open" : "Unavailable", symbol: "arrow.up.right", enabled: available && !pending)
            row(.observe, title: "Mute", symbol: "bell.slash", enabled: true)
        }
        .padding(Theme.Spacing.sm)
        .frame(width: width)
        .panelSurface()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.agentActions, style: .continuous))
    }

    private func row(_ action: AgentMenuAction, title: String, symbol: String, enabled: Bool) -> some View {
        let highlighted = enabled && selection.action == action
        let ink = highlighted ? Theme.Colors.highlightInk : enabled ? Theme.Colors.textPrimary : Theme.Colors.textTertiary
        return Button { perform(action) } label: {
            HStack(spacing: Theme.Spacing.md) {
                RowSymbol(symbol: symbol, tint: ink, slotSize: Theme.Size.menuIcon, role: .menu)
                Text(title).font(Theme.Typography.rowTitle).foregroundStyle(ink)
                Spacer(minLength: Theme.Spacing.xs)
                if action == .observe, store.isObserveOnly(destination) {
                    RowSymbol(symbol: "checkmark", tint: ink, slotSize: Theme.Size.menuIcon, role: .menu)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: Theme.Size.menuRowHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.menuRow, style: .continuous)
                .fill(highlighted ? Theme.Colors.highlight : Theme.Colors.noFill))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.menuRow, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onContinuousHover { phase in if case .active = phase { hover(action) } }
        .accessibilityLabel(title)
        .accessibilityValue(action == .observe ? (store.isObserveOnly(destination) ? "On" : "Off") : "")
    }
}
