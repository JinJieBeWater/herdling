import AppKit
import SwiftUI

/// The panel's floating bottom bar: a refresh control on the leading edge, Settings on the
/// trailing one, and nothing in between.

struct PanelFooter: View {
    let store: SessionStore
    let onOpenSettings: () -> Void

    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            refreshButton
            Spacer(minLength: 0)
            settingsCommand
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: Theme.Size.footerHeight)
        // The safe-area inset hands its content the slot it gets; without this the bar's controls
        // stretch with the panel while it animates between heights, and a circle in a stretched
        // frame is an ellipse.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PanelContentHeightKey.self,
                    value: PanelHeightMeasurement(header: geometry.size.height)
                )
            }
        }
    }

    private var refreshButton: some View {
        BarButton(
            isCompact: true,
            help: "Refresh now",
            accessibilityLabel: "Refresh now"
        ) {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                await store.refresh()
                isRefreshing = false
            }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Glyph.refresh)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .frame(width: Theme.Size.refreshGlyph, height: Theme.Size.refreshGlyph)
        }
        // The fixed frame sits outside the label, because the label is what the bar's slot
        // stretches while the panel animates between heights — and a circle drawn in a stretched
        // frame is an ellipse. That is what the first version of this bar drew.
        .frame(width: Theme.Size.footerControl, height: Theme.Size.footerControl)
        .accessibilityHint("Reloads every source now")
    }

    /// The footer's one command.
    ///
    /// Quit is deliberately absent: it is in the app menu (⌘Q) and in the status item's menu, and a
    /// third copy on the panel's prime real estate would promote an exit command over the roster the
    /// panel exists to show. Settings is not a primary action either, so it does not take the
    /// primary weight — the footer says "chrome" by staying quiet until the pointer arrives.
    private var settingsCommand: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            BarButton(action: onOpenSettings) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Settings")
                        .font(Theme.Typography.bar)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    KeyCapChip(text: "⌘,")
                }
            }
            .help("Open Settings")
            .accessibilityLabel("Settings")
        }
        .padding(Theme.Spacing.xs)
    }
}
