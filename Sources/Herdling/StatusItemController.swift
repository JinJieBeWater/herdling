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
    static let panelWidth: CGFloat = 420
    static let panelTopMargin: CGFloat = 0
    static let panelBottomMargin: CGFloat = 16
    static let panelMinHeight: CGFloat = 100
    static let panelScreenFraction: CGFloat = 0.85
    private let store: SessionStore
    private let menuBarItem = MenuBarStatusItem()
    private let panel = MenuBarPanel()
    private lazy var hostingController = NSHostingController(rootView: AgentListView(store: store))
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
            // NSGlassEffectView with the hosting view as its contentView, which is how AppKit embeds
            // content in glass. Regular rather than clear: clear takes its tone from the backdrop
            // while the labels follow the appearance, which pairs dark text with a dark panel.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = PanelRadius.panel
            glass.tintColor = NSColor(white: 1, alpha: 0.04)
            glass.contentView = hostingController.view
            panel.contentView = glass
        } else {
            panel.contentViewController = hostingController
        }
        panel.setContentSize(NSSize(width: Self.panelWidth, height: preferredPanelHeight))

        store.onChange = { [weak self] in self?.updateStatus() }
        store.onClientActivated = { [weak self] in self?.closePanel() }
        updateStatus()
    }

    deinit {
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

        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings")
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Herdling", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Herdling")
        menu.addItem(quit)

        menuBarItem.item.menu = menu
        menuBarItem.item.button?.performClick(nil)
        menuBarItem.item.menu = nil
    }

    @objc func openSettings() {
        store.setShowingSettings(true)
        if !panel.isVisible { openPanel() }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func openPanel() {
        guard let button = menuBarItem.item.button,
              let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return }

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

                guard keyCode == 53 else { return false }
                switch Self.escapeAction(showingSettings: self.store.showingSettings) {
                case .showRoster:
                    self.store.setShowingSettings(false)
                case .closePanel:
                    self.closePanel()
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    enum EscapeAction: Equatable {
        case showRoster
        case closePanel
    }

    nonisolated static func escapeAction(showingSettings: Bool) -> EscapeAction {
        showingSettings ? .showRoster : .closePanel
    }

    private func updateStatus() {
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
}
