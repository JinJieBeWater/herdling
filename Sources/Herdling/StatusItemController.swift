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

        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: Self.panelWidth, height: preferredPanelHeight))

        store.onChange = { [weak self] in self?.updateStatus() }
        updateStatus()
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
        max(ceil(height), 100)
    }

    static func resizedVisiblePanelFrame(
        currentFrame: NSRect,
        preferredHeight: CGFloat,
        visibleFrame: NSRect
    ) -> NSRect {
        let height = min(
            preferredHeight,
            max(1, currentFrame.maxY - visibleFrame.minY - panelBottomMargin)
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

    static func availablePanelHeight(buttonRect: NSRect, visibleFrame: NSRect) -> CGFloat {
        max(
            1,
            panelTopY(buttonRect: buttonRect, visibleFrame: visibleFrame)
                - visibleFrame.minY
                - panelBottomMargin
        )
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
                availablePanelHeight(buttonRect: buttonRect, visibleFrame: visibleFrame)
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
