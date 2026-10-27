import AppKit
import os
import SwiftUI

enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    @MainActor static var applyHeight: ((CGFloat) -> Void)?

    nonisolated static func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.pendingHeight = nil
            $0.isScheduled = false
        }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let (generation, shouldSchedule) = state.withLock { state in
            state.pendingHeight = height
            let generation = state.generation
            guard !state.isScheduled else { return (generation, false) }
            state.isScheduled = true
            return (generation, true)
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async {
            let height = state.withLock { state -> CGFloat? in
                guard state.generation == generation else { return nil }
                let height = state.pendingHeight
                state.pendingHeight = nil
                state.isScheduled = false
                return height
            }
            guard let height else { return }
            MainActor.assumeIsolated { applyHeight?(height) }
        }
    }
}

@MainActor
final class StatusItemController: NSObject {
    static let panelWidth: CGFloat = Theme.Size.panelWidth
    static let panelTopMargin: CGFloat = Theme.Size.panelTopMargin
    static let panelBottomMargin: CGFloat = Theme.Size.panelBottomMargin
    static let panelMinHeight: CGFloat = Theme.Size.panelMinHeight
    static let panelScreenFraction: CGFloat = Theme.Size.panelScreenFraction
    private let store: SessionStore
    private let browser = NavigationBrowser()
    private let menuBarItem = MenuBarStatusItem()
    private let panel = MenuBarPanel()
    private var settingsController: SettingsWindowController?
    private var isRefreshing = false
    private lazy var hostingController = NSHostingController(
        rootView: AgentListView(store: store, browser: browser)
    )
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItems: [menuBarItem.item],
        onDismiss: { [weak self] in self?.closePanel() }
    )
    private var keyMonitor: Any?
    private var lastStatus: MenuStatus?
    private var preferredPanelHeight: CGFloat = 340

    init(store: SessionStore) {
        self.store = store
        super.init()

        PanelHeightBridge.applyHeight = { [weak self] height in
            self?.updatePanelHeight(height)
        }

        menuBarItem.onClick = { [weak self] in self?.statusButtonClicked() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenGeometryChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenGeometryChanged(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )

        hostingController.sizingOptions = []
        if #available(macOS 26.0, *) {
            panel.contentView = panelGlass(wrapping: hostingController.view, cornerRadius: Theme.Radius.panel)
        } else {
            panel.contentViewController = hostingController
        }
        panel.setContentSize(NSSize(width: Self.panelWidth, height: preferredPanelHeight))

        store.onChange = { [weak self] in self?.updateStatus() }
        store.onClientActivated = { [weak self] in self?.closePanel() }
        PanelShortcut.register { [weak self] in self?.togglePanelFromKeyboard() }
        updateStatus()
    }

    isolated deinit {
        PanelShortcut.unregister()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func showContextMenu() {
        if panel.isVisible { closePanel() }

        let menu = HerdlingApplicationMenu.makeContext(target: self, isRefreshing: isRefreshing)
        menuBarItem.item.menu = menu
        menuBarItem.item.button?.performClick(nil)
        menuBarItem.item.menu = nil
    }

    @objc func openSettings() {
        if panel.isVisible { closePanel() }
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store)
        }
        settingsController?.show()
    }

    @objc func refreshSources() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            await store.refresh()
        }
    }

    private func openPanel(keyboard: Bool = false) {
        guard let button = menuBarItem.item.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return }

        browser.open(sources: store.sources,
                     attempt: store.navigationAttempt, keyboard: keyboard,
                     expandedSourceID: store.expandedSourceID)
        browser.holdPointer(at: NSEvent.mouseLocation)
        PanelHeightBridge.invalidate()
        hostingController.view.layoutSubtreeIfNeeded()
        resizePanel(button: button, window: window, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        // The status item window can still report its previous display right after launch, which
        // parked the panel on another screen; re-apply once the button has settled.
        Task { @MainActor [weak self] in
            guard let self,
                  panel.isVisible,
                  let button = menuBarItem.item.button,
                  let buttonWindow = button.window
            else { return }
            resizePanel(button: button, window: buttonWindow, screen: buttonWindow.screen ?? screen)
        }
        panel.makeFirstResponder(nil)
        menuBarItem.setHighlighted(true)
        store.setPanelOpen(true)
        outsideClickMonitor.start()
        installKeyMonitor()
    }

    func showPanel() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            openPanel()
        }
    }

    func togglePanelFromKeyboard() {
        if panel.isVisible { closePanel() }
        else { openPanel(keyboard: true) }
    }

    @objc private func screenGeometryChanged(_ notification: Notification) {
        if notification.name == NSWindow.didChangeScreenNotification,
           notification.object as? NSWindow !== menuBarItem.item.button?.window
        {
            return
        }
        guard panel.isVisible,
              let button = menuBarItem.item.button,
              let window = button.window,
              let screen = window.screen ?? panel.screen ?? NSScreen.main
        else { return }
        resizePanel(button: button, window: window, screen: screen)
    }

    private func closePanel() {
        browser.close()
        PanelHeightBridge.invalidate()
        panel.orderOut(nil)
        panel.makeFirstResponder(nil)
        menuBarItem.setHighlighted(false)
        store.setPanelOpen(false)
        outsideClickMonitor.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let windowID = event.window.map(ObjectIdentifier.init)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      self.panel.isVisible,
                      windowID == ObjectIdentifier(self.panel),
                      !(self.panel.firstResponder is NSText)
                else { return false }

                switch PanelKeyboard.handle(keyCode, modifiers: event.modifierFlags, browser: self.browser) {
                case .passThrough: return false
                case .close: self.closePanel()
                case .handled: self.panel.makeFirstResponder(nil)
                case let .navigate(destination): self.store.navigate(to: destination)
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private func updateStatus() {
        browser.receive(sources: store.sources, attempt: store.navigationAttempt)
        let status = store.menuStatus
        guard status != lastStatus else { return }
        lastStatus = status
        menuBarItem.update(status)
    }

    private func updatePanelHeight(_ contentHeight: CGFloat) {
        let height = Self.clampedContentHeight(contentHeight)
        guard abs(height - preferredPanelHeight) >= 1 else { return }
        preferredPanelHeight = height

        guard panel.isVisible else {
            panel.setContentSize(NSSize(width: Self.panelWidth, height: height))
            return
        }
        guard let screen = panel.screen ?? menuBarItem.item.button?.window?.screen ?? NSScreen.main else { return }
        panel.setFrame(
            Self.resizedVisiblePanelFrame(
                currentFrame: panel.frame,
                preferredHeight: height,
                visibleFrame: screen.visibleFrame
            ),
            display: true
        )
    }

    private func resizePanel(button: NSStatusBarButton, window: NSWindow, screen: NSScreen) {
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = Self.panelSize(
            preferred: NSSize(width: Self.panelWidth, height: preferredPanelHeight),
            buttonRect: buttonRect,
            visibleFrame: screen.visibleFrame
        )
        let origin = Self.panelOrigin(
            buttonRect: buttonRect,
            panelSize: size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    static func clampedContentHeight(_ height: CGFloat) -> CGFloat {
        max(ceil(height), panelMinHeight)
    }

    static func maximumPanelHeight(topY: CGFloat, visibleFrame: NSRect) -> CGFloat {
        max(
            1,
            min(
                topY - visibleFrame.minY - panelBottomMargin,
                floor(visibleFrame.height * panelScreenFraction)
            )
        )
    }

    static func resizedVisiblePanelFrame(
        currentFrame: NSRect,
        preferredHeight: CGFloat,
        visibleFrame: NSRect
    ) -> NSRect {
        let height = min(
            preferredHeight,
            maximumPanelHeight(topY: currentFrame.maxY, visibleFrame: visibleFrame)
        )
        return NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - height,
            width: currentFrame.width,
            height: height
        )
    }

    static func panelOrigin(buttonRect: NSRect, panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let horizontalMargin: CGFloat = 8
        let x = min(
            max(buttonRect.minX, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - panelSize.width - horizontalMargin
        )
        let y = max(
            panelTopY(buttonRect: buttonRect, visibleFrame: visibleFrame) - panelSize.height,
            visibleFrame.minY + panelBottomMargin
        )
        return NSPoint(x: x, y: y)
    }

    static func panelTopY(buttonRect: NSRect, visibleFrame: NSRect) -> CGFloat {
        min(buttonRect.minY - panelTopMargin, visibleFrame.maxY - panelTopMargin)
    }

    static func panelSize(preferred: NSSize, buttonRect: NSRect, visibleFrame: NSRect) -> NSSize {
        let margin: CGFloat = 8
        return NSSize(
            width: min(preferred.width, max(1, visibleFrame.width - margin * 2)),
            height: min(
                preferred.height,
                maximumPanelHeight(
                    topY: panelTopY(buttonRect: buttonRect, visibleFrame: visibleFrame),
                    visibleFrame: visibleFrame
                )
            )
        )
    }
}

@MainActor
final class MenuBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        hidesOnDeactivate = false
        hasShadow = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keeps the glass's active refraction while another window holds key focus, as `NSPopupMenuWindow`
    /// does; without it Liquid Glass turns flat whenever the panel is not key.
    /// shortcut: private AppKit hook; if a future macOS renames it, the glass only loses refraction when not key.
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}
