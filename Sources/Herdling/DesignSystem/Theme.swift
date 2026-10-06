import AppKit
import SwiftUI

/// Herdling's design tokens — the single source of truth for spacing, radii, sizes, type and colour.
///
/// The design language is Tinycast's (see `docs/ui.md`); the values here are Herdling's own and are
/// independent of it. Nothing in the UI should hardcode a number this file already states.
enum Theme {

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12

        /// Space above every group header but the first, reading as the previous group's close.
        static let sectionSpacing: CGFloat = 12
        /// A row's own top and bottom breathing room, and with it the panel's row pitch.
        ///
        /// 8 puts `rowIcon 22` on a **38pt** row, which is tinycast's row height for `.body` text
        /// (its 26pt slot plus `Spacing.sm` twice). At 5 the pitch was 32 and two lines of 17pt text
        /// had 19.5pt of air between them against tinycast's 25.5 — the list read cramped however
        /// tidy its columns were.
        static let rowVertical: CGFloat = 8
        /// One level of nesting: a child's content steps in by this much.
        static let indent: CGFloat = 6
    }

    // MARK: - Radius

    enum Radius {
        /// The panel corner. The one number that says which product this is.
        static let panel: CGFloat = 26
        /// A row's hover and selection fill. A rounded rectangle, not a stadium: a row is content,
        /// and a 32pt row with a 16pt radius turns every fill into a lozenge, which makes a list of
        /// agents read as a column of controls.
        static let row: CGFloat = 10
        /// A leading glyph's plate. Small-cornered, so it reads as a category mark rather than the
        /// avatar a full disc would read as — and the glyph has to fill it (`tileGlyphRatio`), or an
        /// empty plate makes its corner the loudest thing in the row.
        static let tile: CGFloat = 6
        static let keyCap: CGFloat = 6
    }

    // MARK: - Size

    enum Size {
        static let panelWidth: CGFloat = 420
        static let panelMinHeight: CGFloat = 100
        /// The floating bottom bar. Its height is part of the panel's measured height, and its slack
        /// is pinned from below by the panel's corner — see `docs/ui.md`.
        static let footerHeight: CGFloat = 52
        static let barButtonHeight: CGFloat = 28
        /// The footer's round control. Stated as the command pill's own height (a 28pt bar button
        /// plus `Spacing.xs` either side), so the bar's left and right read as one line of chrome; at
        /// the bar button's height the left side looks like a smaller, separate control.
        static let footerControl: CGFloat = 36
        /// The fixed leading slot of a row glyph. A smaller glyph centres inside it.
        static let rowIcon: CGFloat = 22
        /// A space label's band. Taller than its text on purpose: the label sits between rows that
        /// are a full `rowIcon` tall, and at the text's own height it reads as one more row rather
        /// than as the heading of the ones below it.
        static let labelBand: CGFloat = 26
        static let keyCap: CGFloat = 18
        /// A disclosure chevron's slot. Every trailing readout reserves it, so summaries, focus
        /// arrows and chevrons all end on one column.
        static let chevron: CGFloat = 12
        /// A row's floor, for the rows whose content is shorter than the glyph slot. Every row is
        /// `rowIcon + rowVertical * 2` tall in practice; this only keeps a thin row from collapsing.
        static let rowMinHeight: CGFloat = 26
        /// A trailing action pill's height.
        static let actionPill: CGFloat = 20
        /// The refresh control's glyph box, centred in its circle.
        static let refreshGlyph: CGFloat = 16
        /// A spinner that stands in for a row's leading glyph.
        static let progressIndicator: CGFloat = 12
        /// How much of a leading tile its glyph fills. Too small and the plate reads empty, which
        /// makes its corner the loudest thing in the row.
        static let tileGlyphRatio: CGFloat = 0.64
        /// The menu-bar strip's own scale. It is drawn into an image at menu-bar size, not at the
        /// panel's, so it carries its own numbers rather than borrowing the row's.
        static let menuBarGlyphWidth: CGFloat = 11
        static let menuBarGlyphHeight: CGFloat = 13
        /// Where the panel sits: flush under the menu bar, and this far above the screen's bottom
        /// when the content is taller than the screen.
        static let panelTopMargin: CGFloat = 0
        static let panelBottomMargin: CGFloat = 16
        /// The panel's ceiling as a fraction of the screen's visible height.
        static let panelScreenFraction: CGFloat = 0.85
        /// How far the bottom fade reaches past the footer it passes under, so a row is already
        /// ghosting before it reaches the bar.
        static let fadeOvershoot: CGFloat = 24
        static let settingsWidth: CGFloat = 560
        /// The window's opening height; the Form may be resized down to `settingsMinHeight`.
        static let settingsHeight: CGFloat = 560
        static let settingsRowIcon: CGFloat = 20
        /// Settings defaults to this tall, and never opens shorter.
        static let settingsMinHeight: CGFloat = 420
    }

    // MARK: - Typography

    /// System text styles only. A fixed point size in a view is a regression.
    enum Typography {
        /// Agent, worktree and session titles.
        static let rowTitle = Font.body
        /// Activity summaries, status words, trailing kind labels.
        static let rowTrailing = Font.callout
        /// A group's title.
        static let sectionHeader = Font.subheadline.weight(.medium)
        /// Space labels, branch names, subtitles.
        static let groupLabel = Font.caption
        /// A footer pill's label.
        static let bar = Font.callout.weight(.medium)
        /// A keycap chip.
        static let keyCap = Font.caption
        /// A branch name.
        static let mono = Font.caption.monospaced()
    }

    // MARK: - Glyphs

    /// SF Symbol treatments the panel draws at explicit sizes. They are type, so they live here
    /// rather than as loose point sizes at each call site.
    enum Glyph {
        /// A row's leading status mark.
        static let status = Font.system(size: 11, weight: .semibold)
        /// A disclosure chevron.
        static let chevron = Font.system(size: 10, weight: .semibold)
        /// The glyph inside a trailing action pill.
        static let actionSymbol = Font.system(size: 9, weight: .semibold)
        /// The arrow that appears on a hovered row.
        static let focusArrow = Font.system(size: 10)
        /// The refresh control's arrow.
        static let refresh = Font.system(size: 12, weight: .medium)
        /// An empty state's mark.
        static let emptyState = Font.system(size: 15, weight: .medium)
        /// The menu-bar strip's mark, and its count.
        static let menuBar = Font.system(size: 11, weight: .medium)
        static let menuBarDigit = Font.system(size: 11, weight: .semibold, design: .monospaced)
    }

    // MARK: - Duration

    enum Duration {
        /// A group folding or unfolding.
        static let expand: TimeInterval = 0.18
    }

    // MARK: - Colours

    /// The alpha ramp. Every ink and fill on the panel is one of these; a view never reaches for
    /// `.gray`, a bare `Color.white.opacity(…)`, or `NSColor.windowBackgroundColor`.
    enum Colors {
        /// Resolves against the view's `effectiveAppearance`, so a token repaints on its own.
        static func adaptive(dark: NSColor, light: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
        }

        /// The ramp: white ink over the dark surface, black ink over the light one.
        static func ramp(dark: Double, light: Double) -> Color {
            adaptive(dark: .ink(1, alpha: dark), light: .ink(0, alpha: light))
        }

        /// The ramp's inverse: it darkens the dark surface and lightens the light one.
        static let panelScrim = adaptive(
            dark: .ink(0, alpha: 0.40), light: .ink(1, alpha: 0.55))

        /// A group header that is open, and a keyboard selection. Beats hover.
        static let selection = ramp(dark: 0.10, light: 0.09)
        /// Mouse hover, always fainter than selection.
        static let rowHover = ramp(dark: 0.05, light: 0.045)
        /// Small control surfaces: keycaps, a leading glyph tile's fill.
        static let controlSurface = ramp(dark: 0.10, light: 0.08)

        /// Alpha 1, so a call site can dim it with `.opacity` and land on the value it replaced.
        static let textPrimary = ramp(dark: 1.0, light: 1.0)
        static let textSecondary = ramp(dark: 0.60, light: 0.60)
        static let textTertiary = ramp(dark: 0.40, light: 0.42)

        /// A glyph tile's fill, at the tint's own hue.
        static func tileFill(_ tint: Color) -> Color { tint.opacity(tileFillAlpha) }

        /// How strongly a tile's plate carries its tint.
        static let tileFillAlpha: Double = 0.12
        /// The panel glass's own tint, laid on by AppKit before the scrim.
        static let glassTint = NSColor(white: 1, alpha: 0.04)
        /// The furthest a row fades under the footer: it still ghosts, it never disappears.
        static let fadeFloor: Double = 0.25

    }

    /// The hues the panel's leading marks are tinted with. Named as hues, not roles: a source is
    /// blue here and a Settings row is blue there, and one token serves both.
    enum Hue {
        static let indigo = Color.indigo
        static let blue = Color.blue
        static let purple = Color.purple
        static let orange = Color.orange
        static let green = Color.green
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    /// An sRGB grey at one alpha; the ramp's ink. Never a named or semantic colour.
    static func ink(_ white: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
}
