import SwiftUI

/// A panel row that reports a failure, laid out like every other row: leading badge, label-coloured
/// text, and the action as a button whose emphasis sits on its own glass background rather than on
/// accent-coloured text.
struct ErrorRow: View {
    let message: String
    var retry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RosterBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, size: 18)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }

            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let retry {
                Button("Retry now", action: retry)
                    .font(.system(size: 11, weight: .medium))
                    .modifier(PanelActionButton())
                    .accessibilityHint("Retries this source immediately")
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }
}

/// Emphasis on the button's own surface, which is where the guidance puts accent colour, instead of
/// on accent-coloured text.
struct PanelActionButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
