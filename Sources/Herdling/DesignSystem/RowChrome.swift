import AppKit
import SwiftUI

/// The shared row grammar: one leading glyph slot, a title, an optional trailing label.
///
/// Roster titles at the same visible depth share a column. See `docs/ui.md`.

/// A clickable row; the browser owns the single highlight, the row owns its local hover affordance.
struct HoverRow<Content: View>: View {
    var minHeight: CGFloat = Theme.Size.rowMinHeight
    var verticalPadding: CGFloat = Theme.Spacing.rowVertical
    /// Indents content only; the highlight and click target remain full width.
    var indent: CGFloat = 0
    var enabled = true
    let accessibilityText: String
    var accessibilityHint: String? = "Opens this item in your selected terminal"
    var action: () -> Void
    @ViewBuilder var content: (Bool) -> Content

    @State private var isHovered = false
    @Environment(\.panelIsOpen) private var panelIsOpen
    @Environment(\.navigationBrowser) private var navigationBrowser
    @Environment(\.navigationRowID) private var navigationRowID

    private var keyboardSelected: Bool {
        navigationRowID != nil && navigationBrowser?.keyboardSelection == navigationRowID
    }

    private var available: Bool {
        guard let navigationBrowser, case let .destination(destination) = navigationRowID else { return enabled }
        return enabled && navigationBrowser.isAvailable(destination)
    }

    private var navigationValue: String {
        var values = keyboardSelected || highlighted ? ["Selected"] : []
        if !available { values.append("Unavailable") }
        if case let .destination(destination) = navigationRowID,
           let attempt = navigationBrowser?.attempt, attempt.destination == destination {
            switch attempt.phase {
            case .pending: values.append("Opening")
            case .failed: values.append(attempt.message.map { "Failed: \($0)" } ?? "Failed")
            case .succeeded: break
            }
        }
        return values.joined(separator: ", ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) { content(isHovered && available) }
                // On the accent highlight, hierarchical ink turns white the way a native menu's does.
                .environment(\.backgroundProminence, highlighted ? .increased : .standard)
                .padding(.leading, Theme.Spacing.rowHorizontal + indent)
                .padding(.trailing, Theme.Spacing.rowHorizontal)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(accessibilityText)
        .modifier(OptionalAccessibilityHint(hint: accessibilityHint))
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill)
                .allowsHitTesting(false)
            if let navigationBrowser, let navigationRowID {
                RosterPointerTracking(
                    moved: { navigationBrowser.selectFromPointer(navigationRowID, at: $0) },
                    exited: { navigationBrowser.pointerExited(navigationRowID) }
                )
            }
        }
        .accessibilityValue(navigationValue)
        .onHover { isHovered = $0 }
        // No hover-exit arrives while the panel is ordered out, so clear what was lit.
        .onChange(of: panelIsOpen) { _, isOpen in if isOpen { isHovered = false } }
    }

    private var highlighted: Bool {
        guard available else { return false }
        if let navigationBrowser, let navigationRowID {
            return navigationBrowser.highlightedSelection == navigationRowID
        }
        return isHovered && (navigationBrowser?.allowsPointerHighlight ?? true)
    }

    /// An unavailable keyboard target keeps
    /// a neutral surface: still visible, without the accent that promises it opens.
    private var fill: AnyShapeStyle {
        guard available else { return keyboardSelected ? Theme.Colors.unavailableSelection : Theme.Colors.noFill }
        return highlighted ? Theme.Colors.highlight : Theme.Colors.noFill
    }
}

/// Layout and scrolling can synthesize hover entry; only a moved screen position claims selection.
struct RosterPointerTracking: NSViewRepresentable {
    let moved: (NSPoint) -> Void
    var exited: () -> Void = {}

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.moved = moved
        view.exited = exited
    }

    final class TrackingView: NSView {
        var moved: ((NSPoint) -> Void)?
        var exited: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func mouseMoved(with event: NSEvent) {
            guard let window = event.window else { return }
            moved?(window.convertPoint(toScreen: event.locationInWindow))
        }
        override func mouseExited(with event: NSEvent) { exited?() }
    }
}

private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

/// A bare leading glyph shared by groups, sources, statuses, errors and Settings.
struct RowSymbol: View {
    enum Role { case list, navigation }
    let symbol: String
    let tint: AnyShapeStyle
    var slotSize: CGFloat = Theme.Size.rowIcon
    var role: Role = .list
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                Image(nsImage: image).renderingMode(.template)
            }
        }
        // Status hues would vanish into the accent highlight; native menus draw icons white there.
        .foregroundStyle(prominence == .increased ? Theme.Colors.textPrimary : tint)
        .frame(width: slotSize, height: slotSize)
        .accessibilityHidden(true)
    }

    private var configuration: NSImage.SymbolConfiguration {
        switch role {
        case .list: Theme.Glyph.leadingSymbol
        case .navigation: Theme.Glyph.navigationSymbol
        }
    }
}

extension RowSymbol {
    /// Status and hue marks arrive as plain colours. Without one, a neutral status still has to read
    /// as a status, so it takes secondary ink; tertiary on glass is too faint for that.
    init(symbol: String, tint: Color?, slotSize: CGFloat = Theme.Size.rowIcon, role: Role = .list) {
        self.init(symbol: symbol, tint: tint.map { AnyShapeStyle($0) } ?? Theme.Colors.textSecondary,
                  slotSize: slotSize, role: role)
    }
}

/// A quiet state for a group with nothing to show, centred the way a palette's empty list is.
struct RosterEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol)
                .font(Theme.Glyph.emptyState)
                .foregroundStyle(Theme.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

/// A small inline command: bare at rest, the shared accent highlight under the pointer.
struct RosterActionPill: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.panelIsOpen) private var panelIsOpen
    @Environment(\.navigationBrowser) private var navigationBrowser
    @Environment(\.navigationRowID) private var navigationRowID

    private var highlighted: Bool { isHovered && (navigationBrowser?.allowsPointerHighlight ?? true) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(Theme.Glyph.actionSymbol)
                }
                Text(title)
                    .font(Theme.Typography.groupLabel.weight(.medium))
            }
            .foregroundStyle(highlighted ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
            .environment(\.backgroundProminence, highlighted ? .increased : prominence)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: Theme.Size.actionPill)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(highlighted && prominence != .increased ? Theme.Colors.highlight : Theme.Colors.noFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if let navigationBrowser {
                RosterPointerTracking(moved: { navigationBrowser.selectFromPointer(navigationRowID, at: $0) })
            }
        }
        .onHover { isHovered = $0 }
        .onChange(of: panelIsOpen) { _, isOpen in if isOpen { isHovered = false } }
    }
}

struct DisclosureChevron: View {
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.Glyph.chevron)
            .foregroundStyle(prominence == .increased ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
            .animation(AccordionMotion.animation(reduceMotion: accessibilityReduceMotion)) { image in
                image.rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .frame(width: Theme.Size.chevron)
            .accessibilityHidden(true)
    }
}

/// How a source presents itself in the roster's leading mark.
///
/// This lives with the row chrome rather than on `SourceInfo`: the local/remote judgement is a
/// presentation decision, and putting it on the model type meant the store had to import SwiftUI to
/// answer "what colour is this". It also used to be written out at three call sites, two of which
/// had already drifted apart.
extension SourceInfo {
    var rosterSymbol: String { descriptor.sshAlias == nil ? "desktopcomputer" : "network" }
    var rosterTint: AnyShapeStyle { Theme.Colors.textSecondary }
}
