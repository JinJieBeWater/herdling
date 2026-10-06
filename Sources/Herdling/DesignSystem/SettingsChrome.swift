import SwiftUI

// The pieces Settings' panes share. A pane is a stock grouped `Form`, so cards, row insets and
// hairlines are system-drawn; these only dress a row's own label.

/// A row's label: an optional tinted icon tile, a title, and the subtitle that states a consequence
/// or a limit the title leaves out.
struct SettingsLabel: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            if let symbol {
                // Same glyph-to-plate ratio as `RosterTile`, so the two tiles are one object.
                Image(systemName: symbol)
                    .font(.system(size: Theme.Size.settingsRowIcon * Theme.Size.tileGlyphRatio, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
                    .background(
                        Theme.Colors.tileFill(tint),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    )
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.groupLabel)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
