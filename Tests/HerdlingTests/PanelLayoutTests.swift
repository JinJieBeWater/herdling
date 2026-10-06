import AppKit
import SwiftUI
import Testing
@testable import Herdling

/// The panel's own measurements, taken with real AppKit geometry.
///
/// These exist for the failures a screenshot review misses: two kinds of row disagreeing on height,
/// a derived radius drifting from the pitch it is derived from, the footer's two controls no longer
/// matching. One test each, for the three invariants that can actually break.
///
/// There is deliberately nothing here about margins *as drawn*: `glassEffect` paints its rim with
/// its own inset, so pixel-measuring it produced failures that were never layout bugs.
@Suite
@MainActor
struct PanelLayoutTests {
    /// One row, whatever it holds: the tile slot plus its own vertical breathing room. Every row
    /// kind resolves to this, which is what makes the panel read as one list.
    private var expectedRowPitch: CGFloat {
        Theme.Size.rowIcon + Theme.Spacing.rowVertical * 2
    }

    @Test
    func everyRowKindSharesOnePitch() {
        let row = fittingHeight {
            HoverRow(accessibilityText: "row", action: {}) { _ in
                RosterTile(symbol: "clock", tint: Theme.Hue.indigo)
                Text("Title")
            }
        }
        #expect(row == expectedRowPitch)

        let header = fittingHeight {
            HoverRow(isSelected: true, accessibilityText: "header", action: {}) { _ in
                RosterTile(symbol: "clock", tint: Theme.Hue.indigo)
                Text("Header")
                DisclosureChevron(isExpanded: true)
            }
        }
        #expect(header == expectedRowPitch)
    }

    /// Surfaces round, content square-ish: the panel and the footer's pill are the round things in
    /// Herdling, and a row's fill or a leading tile that turns into a stadium or a disc stops reading
    /// as content. These two ratios are the line between those families, so they are pinned.
    @Test
    func contentRadiiStayBelowTheirRows() {
        // A fill or a plate may be generously rounded, but never half its box: at half, a 32pt row
        // is a lozenge and a 22pt tile is a disc, and the panel becomes a column of controls.
        #expect(Theme.Radius.row * 2 < expectedRowPitch)
        #expect(Theme.Radius.tile * 2 < Theme.Size.rowIcon)
        #expect(Theme.Radius.row < Theme.Radius.panel)
    }

    /// The footer's two sides are one line of chrome: the round control is the command pill's own
    /// height, not the bar button's.
    ///
    /// And the bar's slack is pinned from below, not chosen. The round control sits `Spacing.md` in
    /// from the panel's left edge, where the panel's own corner lifts the edge by
    /// `panel − √(panel² − (panel − inset)²)`; slack below the control has to clear that, or the
    /// circle's bottom-left is clipped by the corner. Glass rims are not measured here on purpose —
    /// they are drawn by the system and are not our geometry.
    @Test
    func footerControlsShareOneHeightAndClearTheCorner() {
        #expect(Theme.Size.footerControl == Theme.Size.barButtonHeight + Theme.Spacing.xs * 2)

        let store = PreviewFixtures.makeStore()
        let band = fittingHeight {
            PanelFooter(store: store, onOpenSettings: {})
                .frame(width: Theme.Size.panelWidth)
        }
        #expect(band == Theme.Size.footerHeight)

        let slack = (Theme.Size.footerHeight - Theme.Size.barButtonHeight) / 2
        let panel = Theme.Radius.panel
        let inset = Theme.Spacing.md
        let cornerLift = panel - (panel * panel - pow(panel - inset, 2)).squareRoot()
        #expect(
            slack >= cornerLift,
            "the bar's slack is \(slack)pt but the panel's corner lifts \(cornerLift)pt at x=\(inset)"
        )
    }

    private func fittingHeight(@ViewBuilder _ view: () -> some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view())
        hosting.frame = NSRect(x: 0, y: 0, width: Theme.Size.panelWidth, height: 200)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}