import AppKit
import SwiftUI

/// The shared row grammar: one leading glyph slot, a title, an optional trailing label.
///
/// Roster titles at the same visible depth share a column. See `docs/ui.md`.

/// A clickable row with the shared hover fill. Hover state lives here, not in the list, so a mouse
/// sweep repaints only the rows it enters and leaves.
struct HoverRow<Content: View>: View {
    var minHeight: CGFloat = Theme.Size.rowMinHeight
    var verticalPadding: CGFloat = Theme.Spacing.rowVertical
    /// Indents content only; the highlight and click target remain full width.
    var indent: CGFloat = 0
    var enabled = true
    /// A row that stands for something open, or a keyboard selection. Beats hover.
    var isSelected = false
    let accessibilityText: String
    var accessibilityHint: String? = "Opens this item in Ghostty"
    var action: () -> Void
    @ViewBuilder var content: (Bool) -> Content

    @State private var isHovered = false
    @Environment(\.panelIsOpen) private var panelIsOpen
    @Environment(\.rosterScrollbarClearance) private var scrollbarClearance
    @Environment(\.navigationBrowser) private var navigationBrowser
    @Environment(\.navigationRowID) private var navigationRowID

    private var keyboardSelected: Bool {
        navigationRowID != nil && navigationBrowser?.selection == navigationRowID
    }

    private var available: Bool {
        guard let navigationBrowser, case let .destination(destination) = navigationRowID else { return enabled }
        return enabled && navigationBrowser.isAvailable(destination)
    }

    private var navigationValue: String {
        var values = keyboardSelected ? ["Selected"] : []
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
                .padding(.leading, Theme.Spacing.md + indent)
                .padding(.trailing, Theme.Spacing.md + scrollbarClearance)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityLabel(accessibilityText)
        .modifier(OptionalAccessibilityHint(hint: accessibilityHint))
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(fill)
        }
        .overlay {
            if keyboardSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.Colors.textSecondary, lineWidth: Theme.Size.keyboardSelectionStroke)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityValue(navigationValue)
        .onHover { isHovered = $0 }
        // No hover-exit arrives while the panel is ordered out, so clear what was lit.
        .onChange(of: panelIsOpen) { _, isOpen in if isOpen { isHovered = false } }
    }

    /// Selection beats hover, the rule every row follows.
    private var fill: Color {
        guard available else { return .clear }
        if isSelected || keyboardSelected { return Theme.Colors.selection }
        return isHovered ? Theme.Colors.rowHover : .clear
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
    let tint: Color?
    var slotSize: CGFloat = Theme.Size.rowIcon
    var role: Role = .list

    var body: some View {
        Group {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(role == .navigation ? Theme.Glyph.navigationSymbol : Theme.Glyph.leadingSymbol) {
                Image(nsImage: image).renderingMode(.template)
            }
        }
        .foregroundStyle(tint ?? Theme.Colors.textTertiary)
        .frame(width: slotSize, height: slotSize)
        .accessibilityHidden(true)
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

/// A small inline action at the trailing edge of a row: bare at rest, a `rowHover` capsule under the
/// pointer. One implementation for every row's trailing button, so they all speak the same language.
struct RosterActionPill: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(Theme.Glyph.actionSymbol)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                Text(title)
                    .font(Theme.Typography.groupLabel.weight(.medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: Theme.Size.actionPill)
            .background(
                Capsule().fill(isHovered ? Theme.Colors.rowHover : .clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct DisclosureChevron: View {
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(Theme.Glyph.chevron)
            .foregroundStyle(Theme.Colors.textTertiary)
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
    var rosterTint: Color { Theme.Colors.textSecondary }
}
