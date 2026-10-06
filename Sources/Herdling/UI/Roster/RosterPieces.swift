import AppKit
import SwiftUI

// The row vocabulary every roster level is built from: one header shape, one glyph slot, one
// trailing readout, and the measured body that folds. Everything here is internal because the
// levels above live in sibling files.

// MARK: - Group header

/// A group header's contents: a leading mark, a title, and its readout pushed to the panel's edge.
///
/// Pure layout — no padding, no frame — because the two callers supply their own: a folding header
/// wraps it in a `HoverRow` (which brings the hover and selection fills), and a static header draws
/// the row box itself. Either way the chevron's column is reserved, so every header's readout ends
/// on one x.
struct GroupHeaderLine<Leading: View, Subtitle: View, Trailing: View>: View {
    let leading: Leading
    let title: String
    var titleFont: Font = Theme.Typography.sectionHeader
    /// A modifier of the title rather than a readout: a branch says *which* thing this is, so it
    /// belongs beside the name. Left in the trailing cluster it glued itself to the counts — same
    /// colour, same size, one gap — and the two read as one sentence.
    @ViewBuilder var subtitle: Subtitle
    /// Set false by a caller that draws its own chevron or slot next to this line.
    var reservesChevronSlot = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            leading
            Text(title)
                .font(titleFont)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            subtitle
            Spacer(minLength: Theme.Spacing.md)
            trailing
            if reservesChevronSlot {
                Color.clear.frame(width: Theme.Size.chevron)
            }
        }
    }
}

extension GroupHeaderLine where Subtitle == EmptyView {
    init(
        leading: Leading,
        title: String,
        titleFont: Font = Theme.Typography.sectionHeader,
        reservesChevronSlot: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            leading: leading,
            title: title,
            titleFont: titleFont,
            subtitle: { EmptyView() },
            reservesChevronSlot: reservesChevronSlot,
            trailing: trailing
        )
    }
}

/// A group header that folds: a button with the panel's hover and selection fills.
struct GroupHeaderRow<Leading: View, Subtitle: View, Trailing: View>: View {
    let leading: Leading
    let title: String
    var titleFont: Font = Theme.Typography.sectionHeader
    @ViewBuilder var subtitle: Subtitle
    /// nil for a group that does not fold — the chevron is then left out.
    var isExpanded: Bool?
    var indent: CGFloat = 0
    var enabled = true
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HoverRow(
            minHeight: Theme.Size.rowMinHeight,
            indent: indent,
            enabled: enabled,
            isSelected: isExpanded == true,
            accessibilityText: accessibilityLabel,
            accessibilityHint: accessibilityHint,
            action: action
        ) { _ in
            GroupHeaderLine(
                leading: leading,
                title: title,
                titleFont: titleFont,
                subtitle: { subtitle },
                reservesChevronSlot: false,
                trailing: { trailing }
            )
            if let isExpanded {
                DisclosureChevron(isExpanded: isExpanded)
            } else {
                // A group that does not fold still reserves the chevron's slot, so its trailing
                // readout lands on the same x as a folding header's.
                Color.clear.frame(width: Theme.Size.chevron)
            }
        }
    }
}

extension GroupHeaderRow where Subtitle == EmptyView {
    init(
        leading: Leading,
        title: String,
        titleFont: Font = Theme.Typography.sectionHeader,
        isExpanded: Bool?,
        indent: CGFloat = 0,
        enabled: Bool = true,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            leading: leading,
            title: title,
            titleFont: titleFont,
            subtitle: { EmptyView() },
            isExpanded: isExpanded,
            indent: indent,
            enabled: enabled,
            accessibilityLabel: accessibilityLabel,
            accessibilityHint: accessibilityHint,
            action: action,
            trailing: trailing
        )
    }
}

// MARK: - Glyph slot

/// The shared glyph slot. Keeps every row's title at the same x, and centres a glyph narrower than
/// the slot rather than shrinking the slot to it.
struct RowSlot<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
    }
}

// MARK: - Trailing readouts

/// A space's name: the heading of the worktrees below it, one step left of their content.
///
/// `trailing` is where a space's readouts go when it has no worktree row of its own to carry them
/// — a branch and a count, on the same trailing edge every other readout in the panel uses.
struct SpaceLabel<Trailing: View>: View {
    let title: String
    var indent: CGFloat = 0
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(title)
                .font(Theme.Typography.groupLabel.weight(.medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            trailing
        }
        .padding(.leading, Theme.Spacing.md + indent)
        .padding(.trailing, Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.labelBand, alignment: .leading)
    }
}

extension SpaceLabel where Trailing == EmptyView {
    init(title: String, indent: CGFloat = 0) {
        self.init(title: title, indent: indent) { EmptyView() }
    }
}

struct GitBranchLabel: View {
    let summary: BranchSummary

    private var text: String {
        switch summary {
        case let .single(branch): branch
        case .mixed: "mixed"
        }
    }

    var body: some View {
        // Same size and colour as the counts beside it: one trailing readout per row, not two
        // greys at two sizes. The monospaced face is what marks it as a branch.
        Text(text)
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Colors.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(summary == .mixed ? "Multiple branches" : text)
    }
}

struct GroupActivitySummary: View {
    let counts: [AgentStatusCount]

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(counts) { count in
                // One colour for the whole readout, digits included. Bright digits next to dim
                // words read as two different messages; the status hue is already on the row's own
                // glyph, so nothing is lost by keeping the counts neutral.
                Text("\(count.count) \(count.status.rawValue)")
            }
        }
        .font(Theme.Typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textSecondary)
        .fixedSize()
    }
}

struct FocusIndicator: View {
    let isPending: Bool
    let isHovered: Bool

    var body: some View {
        if isPending {
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.circular)
                .frame(
                    width: Theme.Size.progressIndicator,
                    height: Theme.Size.progressIndicator
                )
                .accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.up.right")
                .font(Theme.Glyph.focusArrow)
                .foregroundStyle(Theme.Colors.textTertiary)
                .opacity(isHovered ? 0.8 : 0)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Folding

private struct AccordionContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // max, not last-wins: the content's own default preference is reduced after the measured
        // background value and would otherwise overwrite it with 0.
        value = max(value, nextValue())
    }
}

/// Collapses and expands a group's content by its measured height, so nothing jumps.
struct AccordionBody<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AccordionContentHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(AccordionContentHeightKey.self) { contentHeight = $0 }
            .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(
                AccordionMotion.animation(reduceMotion: accessibilityReduceMotion),
                value: isExpanded
            )
    }
}

extension Collection where Element == AgentStatusCount {
    var primaryStatusText: String { first?.status.rosterLabel ?? "stopped" }
}