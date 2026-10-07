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

        /// Equal clearance around the roster where content follows the panel's corners.
        static let panelInset = md

        /// Distances between boxes, independent of the padding inside each row.
        static let sectionSpacing = xs
        static let groupGap = md
        static let rowGap = xxs
        static let sectionBodyGap = xs
        static let navigationHeaderGap = xs
        static let rowContentGap = sm
        /// Content rows and section headers have separate internal padding, not separate fonts.
        static let rowVertical: CGFloat = 5
        static let sectionHeaderVertical: CGFloat = 8
        /// One level of nesting: a child's content steps in by this much.
        static let indent: CGFloat = 12
    }

    // MARK: - Radius

    enum Radius {
        /// Outer surface and the inset content boundary.
        static let panel: CGFloat = 26
        static let panelContent = panel - Spacing.panelInset
        /// Row corners away from the content boundary.
        static let row: CGFloat = 10
        /// Compact navigation surfaces, independent of their larger click area.
        static let navigationControl: CGFloat = 8
    }

    // MARK: - Size

    enum Size {
        static let panelWidth: CGFloat = 420
        static let panelMinHeight: CGFloat = 100
        /// The fixed leading slot of a row glyph. A smaller glyph centres inside it.
        static let rowIcon: CGFloat = 22
        /// A disclosure chevron's slot. Every trailing readout reserves it, so summaries, focus
        /// arrows and chevrons all end on one column.
        static let chevron: CGFloat = 12
        /// Content-row floor; multiline errors can grow beyond it.
        static let rowMinHeight: CGFloat = 32
        /// Two-line direct destinations and the fixed navigation control row.
        static let quickRowHeight: CGFloat = 40
        static let navigationHeaderHeight: CGFloat = 38
        static let navigationControlHeight: CGFloat = 28
        static let navigationIcon: CGFloat = 14
        /// Neutral outline distinguishes keyboard selection from an expanded header.
        static let keyboardSelectionStroke: CGFloat = 1
        /// A trailing action pill's height.
        static let actionPill: CGFloat = 20
        /// A spinner that stands in for a row's leading glyph.
        static let progressIndicator: CGFloat = 12
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
        /// Bottom-edge fade when content extends below the scroll viewport.
        static let scrollFadeHeight: CGFloat = 24
        static let settingsWidth: CGFloat = 560
        /// The window's opening height; the Form may be resized down to `settingsMinHeight`.
        static let settingsHeight: CGFloat = 560
        /// Settings defaults to this tall, and never opens shorter.
        static let settingsMinHeight: CGFloat = 420
    }

    // MARK: - Typography

    /// System text styles only. A fixed point size in a view is a regression.
    enum Typography {
        /// Agent and worktree titles.
        static let rowTitle = Font.body
        /// Activity summaries, status words, trailing kind labels.
        static let rowTrailing = Font.callout
        /// A group's title.
        static let sectionHeader = Font.subheadline.weight(.medium)
        /// Navigation choices are regular controls, not group titles.
        static let navigationModeLabel = Font.callout
        /// Space labels, branch names, subtitles.
        static let groupLabel = Font.caption
        /// A branch name.
        static let mono = Font.caption.monospaced()
    }

    // MARK: - Glyphs

    /// SF Symbol treatments the panel draws at explicit sizes. They are type, so they live here
    /// rather than as loose point sizes at each call site.
    enum Glyph {
        /// Explicit base symbols: light list marks, medium navigation controls.
        static var leadingSymbol: NSImage.SymbolConfiguration {
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        }
        static var navigationSymbol: NSImage.SymbolConfiguration {
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        }
        /// A disclosure chevron.
        static let chevron = Font.system(size: 10, weight: .semibold)
        /// The glyph inside a trailing action pill.
        static let actionSymbol = Font.system(size: 9, weight: .semibold)
        /// The arrow that appears on a hovered row.
        static let focusArrow = Font.system(size: 10)
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

    enum Scrollbar {
        static let thinWidth: CGFloat = 6
        static let expandedWidth: CGFloat = 10
        static let inset: CGFloat = 3
        static let minimumThumb: CGFloat = 28
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

        /// Alpha 1, so a call site can dim it with `.opacity` and land on the value it replaced.
        static let textPrimary = ramp(dark: 1.0, light: 1.0)
        static let textSecondary = ramp(dark: 0.60, light: 0.60)
        static let textTertiary = ramp(dark: 0.40, light: 0.42)

        static let scrollThumb = ramp(dark: 0.30, light: 0.30)
        static let scrollThumbHover = ramp(dark: 0.42, light: 0.42)
        static let scrollThumbDrag = ramp(dark: 0.50, light: 0.50)
        static let scrollRail = ramp(dark: 0.10, light: 0.10)

        /// The panel glass's own tint, laid on by AppKit before the scrim.
        static let glassTint = NSColor(white: 1, alpha: 0.04)
        /// The furthest a row fades at the scroll edge: it never disappears entirely.
        static let fadeFloor: Double = 0.25

    }

    /// The hues the panel's leading marks are tinted with. Named as hues, not roles: a source is
    /// blue here and a Settings row is blue there, and one token serves both.
    enum Hue {
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
