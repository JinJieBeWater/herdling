import AppKit

@MainActor
final class PanelOutsideClickMonitor {
    private let panel: MenuBarPanel
    private let statusItems: [NSStatusItem]
    private let onDismiss: () -> Void
    private var monitors: [Any] = []

    init(panel: MenuBarPanel, statusItems: [NSStatusItem], onDismiss: @escaping () -> Void) {
        self.panel = panel
        self.statusItems = statusItems
        self.onDismiss = onDismiss
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let windowID = event.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                self?.handleClick(windowID: windowID, screenPoint: NSEvent.mouseLocation)
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(windowID: nil, screenPoint: point)
            }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleClick(windowID: ObjectIdentifier?, screenPoint: NSPoint) {
        guard panel.isVisible else { return }
        if panel.frame.contains(screenPoint) { return }
        if windowID == ObjectIdentifier(panel) { return }
        if statusItems.contains(where: { windowID == $0.button?.window.map(ObjectIdentifier.init) }) { return }
        if isOnStatusButton(screenPoint) { return }
        onDismiss()
    }

    private func isOnStatusButton(_ point: NSPoint) -> Bool {
        statusItems.contains { item in
            guard let button = item.button, let window = button.window else { return false }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            return Self.pointHitsStatusButton(point, buttonFrame: frame, screenTop: window.screen?.frame.maxY)
        }
    }

    nonisolated static func pointHitsStatusButton(_ point: NSPoint, buttonFrame: NSRect, screenTop: CGFloat?) -> Bool {
        guard !buttonFrame.isEmpty else { return false }
        let top = max(buttonFrame.maxY, screenTop ?? buttonFrame.maxY)
        return point.x >= buttonFrame.minX && point.x <= buttonFrame.maxX
            && point.y >= buttonFrame.minY && point.y <= top
    }
}
