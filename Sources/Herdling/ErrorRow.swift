import SwiftUI

/// A panel row that reports a failure, laid out like every other row: leading tile, text on the
/// title column, and the actions as the shared trailing pills rather than as a bordered button that
/// speaks a different language from the rest of the panel.
struct ErrorRow: View {
    let message: String
    var indent: CGFloat = 0
    var retry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            RosterTile(symbol: "exclamationmark.triangle.fill", tint: Theme.Hue.orange)

            Text(message)
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Spacing.md)

            if let retry {
                RosterActionPill(title: "Retry now", symbol: "arrow.clockwise", action: retry)
                    .accessibilityHint("Retries this source immediately")
            }

            if let onDismiss {
                RosterActionPill(title: "Dismiss", symbol: "xmark", action: onDismiss)
                    .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.leading, Theme.Spacing.md + indent)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.rowMinHeight, alignment: .leading)
    }
}