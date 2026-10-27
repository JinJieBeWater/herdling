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

        /// Native menu padding plus one point of overlay-scrollbar clearance.
        static let panelInset: CGFloat = 6
        /// Visible bottom clearance shares the same shell inset as the sides.
        static let panelBottomInset = panelInset

        /// Distances between boxes, independent of the padding inside each row.
        static let sectionSpacing = xs
        static let groupGap = md
        static let rowGap = xxs
        static let sectionBodyGap = xs
        static let navigationHeaderGap = xs
        /// The compact surface sits inside a taller native click area.
        static let navigationVisualInset = (Size.navigationHeaderHeight - Size.navigationControlHeight) / 2
        static let navigationTopInset = panelInset - navigationVisualInset
        /// Shared horizontal content padding for roster rows and compact menu commands.
        static let rowHorizontal = sm
        static let rowContentGap = sm
        /// Account for the narrower navigation slot without changing its glyph treatment.
        static let navigationContentInset = rowHorizontal + (Size.rowIcon - Size.navigationIcon) / 2
        static let navigationContentGap = rowContentGap + (Size.rowIcon - Size.navigationIcon) / 2
        /// Content rows and section headers have separate internal padding, not separate fonts.
        static let rowVertical: CGFloat = 5
        static let sectionHeaderVertical: CGFloat = 8
        /// One level of nesting: a child's content steps in by this much.
        static let indent: CGFloat = 12
    }

    // MARK: - Radius

    enum Radius {
        /// Native menu shell radius and its inset content boundary.
        static let panel: CGFloat = 12
        static let panelContent = CGSize(width: panel - Spacing.panelInset,
                                         height: panel - Spacing.panelBottomInset)
        /// Row corners away from the content boundary.
        static let row: CGFloat = 6
        /// Compact navigation surfaces, independent of their larger click area.
        static let navigationControl = row
    }

    // MARK: - Size

    enum Size {
        static let panelWidth: CGFloat = 420
        static let panelMinHeight: CGFloat = 100
        /// The fixed leading slot of a row glyph. A smaller glyph centres inside it.
        static let rowIcon: CGFloat = 22
        /// Transparent trailing slot keeps disclosure ink outside the native overlay hit strip.
        static let chevron: CGFloat = 20
        /// Content-row floor; multiline errors can grow beyond it.
        static let rowMinHeight: CGFloat = 32
        /// Two-line direct destinations and the fixed navigation control row.
        static let quickRowHeight: CGFloat = 40
        static let navigationHeaderHeight: CGFloat = 38
        static let navigationControlHeight: CGFloat = 28
        static let navigationIcon: CGFloat = 14
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
        static let width: CGFloat = 4
        static let edgeInset: CGFloat = 1
        static let verticalInset: CGFloat = 8
        static let minimumThumb: CGFloat = 28
    }

    // MARK: - Colours

    /// Every ink and fill on the panel is one of these; a view never reaches for `.gray`, a bare
    /// `Color.white.opacity(…)`, or `NSColor.windowBackgroundColor`.
    ///
    /// Hierarchical ink takes the glass's vibrancy. Interaction highlights use the system accent;
    /// quiet unavailable surfaces add light instead of dimming the glass.
    enum Colors {
        /// Resolves against the view's `effectiveAppearance`, so a token repaints on its own.
        static func adaptive(dark: NSColor, light: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
        }

        /// White ink over the dark surface, black ink over the light one, for AppKit drawing.
        static func ramp(dark: Double, light: Double) -> Color {
            adaptive(dark: .ink(1, alpha: dark), light: .ink(0, alpha: light))
        }

        static let noFill = AnyShapeStyle(Color.clear)
        /// Quiet busy backdrops through the native effect, without a second surface over the roster.
        static let glassTint = NSColor(name: nil) { appearance in
            var tint = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                tint = NSColor.windowBackgroundColor.withAlphaComponent(0.20)
            }
            return tint
        }
        /// A keyboard target that became unavailable keeps a quiet positional cue.
        static let unavailableSelection = AnyShapeStyle(adaptive(dark: .ink(1, alpha: 0.10), light: .ink(1, alpha: 0.50)))
        /// Shared by roster hover/keyboard selection, navigation hover and commands.
        static let highlight = AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
        static let highlightInk = AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor))

        static let textPrimary = AnyShapeStyle(.primary)
        static let textSecondary = AnyShapeStyle(PanelSecondaryInk())
        static let textTertiary = AnyShapeStyle(.tertiary)
        /// Panel warning glyphs need stronger light-glass contrast than decorative Settings orange.
        static let warning = adaptive(
            dark: NSColor(srgbRed: 1, green: 0.67, blue: 0.30, alpha: 1),
            light: NSColor(srgbRed: 0.60, green: 0.29, blue: 0, alpha: 1)
        )
        /// Fully opaque ink for masks and template images, where only alpha carries meaning.
        static let opaqueInk = ramp(dark: 1.0, light: 1.0)
        /// Stock grouped Form text follows native semantic ink; the Form is not on the panel glass.
        static let settingsSecondary = Color.secondary
        static let settingsTertiary = Color(nsColor: .tertiaryLabelColor)

        /// AppKit draws the scroller outside SwiftUI's vibrancy, so it keeps fixed-alpha ink.
        static let scrollThumb = ramp(dark: 0.30, light: 0.30)
        static let scrollThumbHover = ramp(dark: 0.42, light: 0.42)
        static let scrollThumbDrag = ramp(dark: 0.50, light: 0.50)

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

private struct PanelSecondaryInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.backgroundProminence == .increased
            ? Theme.Colors.highlightInk : AnyShapeStyle(.secondary)
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
