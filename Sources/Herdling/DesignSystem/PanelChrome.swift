import AppKit
import SwiftUI

// The panel's own chrome: whether it is open, how tall its content is, and how its list dissolves
// into the footer. Everything here is panel-level, not row-level (see `RowChrome.swift`).

/// Whether the panel is on screen. Rows use it to drop hover state left over from the last time it
/// was open, because no hover exit arrives while the panel is ordered out.
private struct PanelOpenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelIsOpen: Bool {
        get { self[PanelOpenKey.self] }
        set { self[PanelOpenKey.self] = newValue }
    }
}

/// The panel's surface: a scrim over the window's own glass.
///
/// The glass itself belongs to `StatusItemController` (an `NSGlassEffectView` as the window's content
/// view, which is where the refraction comes from). This only lays the scrim on top of it, in the
/// order `docs/ui.md` fixes: glass, scrim, content.
struct PanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background(Theme.Colors.panelScrim)
        } else {
            content
                .background(Theme.Colors.panelScrim)
                .background(PanelMaterialBackdrop())
        }
    }
}

/// The pre-Liquid-Glass surface: the system menu material.
private struct PanelMaterialBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The panel's content height, in two parts so a fixed band (a header) can be kept whole while the
/// body is driven by the content that grows.
struct PanelHeightMeasurement: Equatable {
    var header: CGFloat = 0
    var body: CGFloat = 0
    var total: CGFloat { header + body }
}

struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue = PanelHeightMeasurement()

    static func reduce(value: inout PanelHeightMeasurement, nextValue: () -> PanelHeightMeasurement) {
        let next = nextValue()
        value.header = max(value.header, next.header)
        value.body = max(value.body, next.body)
    }
}

/// Publishes a laid-out height through the animation system, so the window resizes in step with the
/// content that made it resize.
struct PanelHeightDriver: GeometryEffect {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            PanelHeightBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        PanelHeightBridge.push(height)
        return ProjectionTransform()
    }
}

enum AccordionMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: Theme.Duration.expand)
    }
}

extension View {
    /// The panel's surface recipe, scrim included.
    func panelSurface() -> some View { modifier(PanelSurface()) }

    /// Softens a list as it passes under the floating footer: a scroll-driven gradient mask whose
    /// ramp starts behind the bar and ends at the window edge, so rows ghost beneath the footer
    /// instead of being cut off by it.
    ///
    /// Not `scrollEdgeEffectStyle`: inside a transparent panel that draws a hard-bounded rectangle.
    func overflowFade() -> some View {
        modifier(OverflowFadeMask())
    }
}

private struct OverflowFadeMask: ViewModifier {
    private struct ScrollState: Equatable {
        /// How much content is hidden below the viewport, 0 when the list rests against its end.
        var hiddenBelow: CGFloat
        var canScroll: Bool
    }

    @State private var hiddenBelow: CGFloat = 0
    @State private var canScroll = false

    private var band: CGFloat { Theme.Size.footerHeight + Theme.Size.fadeOvershoot }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                let visible =
                    geometry.containerSize.height - geometry.contentInsets.top
                    - geometry.contentInsets.bottom
                return ScrollState(
                    hiddenBelow: geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.containerSize.height - geometry.contentOffset.y,
                    canScroll: geometry.contentSize.height > visible
                )
            } action: { _, new in
                hiddenBelow = max(0, new.hiddenBelow)
                canScroll = new.canScroll
            }
            .mask {
                // Spans the scroll view's full frame; the footer's safe-area inset would otherwise
                // shift the gradient onto rows that are at rest.
                GeometryReader { geometry in
                    LinearGradient(
                        stops: stops(height: geometry.size.height),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
            }
    }

    private func stops(height: CGFloat) -> [Gradient.Stop] {
        guard canScroll, height > 0, hiddenBelow > 0 else {
            return [.init(color: .black, location: 0)]
        }
        // Eases from the floor up to solid as the list settles against its end.
        let eased = 1 - (1 - Theme.Colors.fadeFloor) * min(hiddenBelow / band, 1)
        let ramp = min(band / height, 1)
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: 1 - ramp),
            .init(color: .black.opacity(eased), location: 1)
        ]
    }
}
