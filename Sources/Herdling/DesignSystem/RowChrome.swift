import AppKit
import SwiftUI

/// The shared row grammar: one leading glyph slot, a title, an optional trailing label.
///
/// Every list in the panel uses this, so an agent row, a worktree row and a Settings row all start
/// their title at the same x. See `docs/ui.md`.

/// A clickable row with the shared hover fill. Hover state lives here, not in the list, so a mouse
/// sweep repaints only the rows it enters and leaves.
struct HoverRow<Content: View>: View {
    var minHeight: CGFloat = Theme.Size.rowMinHeight
    /// Extra leading inset, so a nested row's content steps in while its highlight still spans the
    /// row's own box — an indented row never gets a stretch of blank highlight on its left.
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) { content(isHovered) }
                .padding(.leading, Theme.Spacing.md + indent)
                .padding(.trailing, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.rowVertical)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityText)
        .modifier(OptionalAccessibilityHint(hint: accessibilityHint))
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(fill)
        }
        .onHover { isHovered = $0 }
        // No hover-exit arrives while the panel is ordered out, so clear what was lit.
        .onChange(of: panelIsOpen) { _, isOpen in if isOpen { isHovered = false } }
    }

    /// Selection beats hover, the rule every row follows.
    private var fill: Color {
        if isSelected { return Theme.Colors.selection }
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

/// A leading glyph in a tinted rounded tile — the panel's one icon treatment for a group or a source.
struct RosterTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = Theme.Size.rowIcon

    var body: some View {
        // The glyph has to fill its plate: at 0.55 the tile read as an empty chip with a loud
        // corner, which is the corner the eye went to instead of the icon.
        Image(systemName: symbol)
            .font(.system(size: size * Theme.Size.tileGlyphRatio, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                Theme.Colors.tileFill(tint),
                in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// A status mark: the semantic status colour on a small glyph, centred in the shared icon slot.
struct StatusIndicator: View {
    let symbol: String
    let tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.Glyph.status)
            .foregroundStyle(tint ?? Theme.Colors.textTertiary)
            .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
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

/// A row's trailing shortcut chip, and the footer's: a filled `controlSurface`.
struct KeyCapChip: View {
    var text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
        Text(text)
            .font(Theme.Typography.keyCap)
            .foregroundStyle(Theme.Colors.textTertiary)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(minWidth: Theme.Size.keyCap, minHeight: Theme.Size.keyCap)
            .background(shape.fill(Theme.Colors.controlSurface))
            .accessibilityHidden(true)
    }
}

/// A bar control: bare at rest, a `rowHover` fill under the pointer, `selection` when it stands for
/// the open surface. Both the footer's pill and its round button are one of these.
struct BarButton<Label: View>: View {
    var isSelected = false
    var isCompact = false
    var help: String?
    var accessibilityLabel: String?
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var isHovered = false

    var body: some View {
        let shape = isCompact ? AnyShape(Circle()) : AnyShape(Capsule())
        Button(action: action) {
            label
                .padding(.horizontal, isCompact ? 0 : Theme.Spacing.md)
                // A compact control is a fixed square: a circle drawn in a stretched frame is an
                // ellipse, which is what a bare `minHeight` leaves behind when a bar hands it more
                // height than it asked for.
                .frame(
                    width: isCompact ? Theme.Size.barButtonHeight : nil,
                    height: Theme.Size.barButtonHeight
                )
                .contentShape(shape)
                .background(shape.fill(fill))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(BarButtonLabels(help: help, accessibilityLabel: accessibilityLabel))
    }

    /// Selection beats hover, the rule every row follows.
    private var fill: Color {
        if isSelected { return Theme.Colors.selection }
        return isHovered ? Theme.Colors.rowHover : .clear
    }
}

private struct BarButtonLabels: ViewModifier {
    let help: String?
    let accessibilityLabel: String?

    func body(content: Content) -> some View {
        if let accessibilityLabel {
            content
                .help(help ?? accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)
        } else {
            content
        }
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
    var rosterTint: Color { descriptor.sshAlias == nil ? Theme.Hue.blue : Theme.Hue.purple }
}
