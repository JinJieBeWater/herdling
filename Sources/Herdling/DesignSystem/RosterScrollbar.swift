import AppKit
import SwiftUI

/// Style the roster's backing scroller, leaving scrolling and overlay fading to AppKit.
struct RosterScrollbarAttachment: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Attachment() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Attachment)?.install()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .zero
    }

    private final class Attachment: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            install()
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // AppKit processes the preference first; then restore this roster's overlay.
                DispatchQueue.main.async { self?.install() }
            }
        }

        override func layout() {
            super.layout()
            install()
        }

        func install() {
            guard let scroll = enclosingScrollView else { return }
            if !(scroll.verticalScroller is RosterScroller) {
                guard let previous = scroll.verticalScroller else { return }
                // NSScroller chooses its axis at init; a zero-sized frame creates the wrong axis.
                let replacement = RosterScroller(frame: previous.frame)
                scroll.verticalScroller = replacement
                replacement.doubleValue = previous.doubleValue
                replacement.knobProportion = previous.knobProportion
                replacement.isEnabled = previous.isEnabled
            }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Parts-only drawing keeps native drag, track clicks, wheel forwarding and accessibility.
final class RosterScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var dragging: Bool { hitPart == .knob }

    override func rect(for part: NSScroller.Part) -> NSRect {
        guard part == .knob || part == .knobSlot else { return super.rect(for: part) }
        let trackHeight = max(0, bounds.height - Theme.Scrollbar.verticalInset * 2)
        let width = Theme.Scrollbar.width
        let x = bounds.maxX - Theme.Scrollbar.edgeInset - width
        if part == .knobSlot {
            return NSRect(x: x, y: Theme.Scrollbar.verticalInset, width: width, height: trackHeight)
        }
        guard isEnabled, knobProportion < 1 else { return .zero }
        let height = min(trackHeight, max(Theme.Scrollbar.minimumThumb, trackHeight * knobProportion))
        let fraction = min(1, max(0, doubleValue))
        let y = Theme.Scrollbar.verticalInset + (isFlipped ? fraction : 1 - fraction) * (trackHeight - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    override func drawKnob() {
        let color = dragging ? Theme.Colors.scrollThumbDrag : hovered ? Theme.Colors.scrollThumbHover : Theme.Colors.scrollThumb
        NSColor(color).setFill()
        capsule(rect(for: .knob)).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Keep the native slot hit geometry, without painting an independent track.
    }

    private func capsule(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true
        needsDisplay = true
        if isEnabled, knobProportion < 1 { (superview as? NSScrollView)?.flashScrollers() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false
        needsDisplay = true
    }
}
