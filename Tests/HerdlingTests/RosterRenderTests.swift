import AppKit
import SwiftUI
import Testing
@testable import Herdling

/// The render harness: lays the panel, Settings and the states out with real AppKit
/// geometry and writes PNGs to a fresh directory for every run.
///
/// It is one test on purpose. It asserts only that each surface laid out at its expected size —
/// which is what catches a view that collapsed to nothing — and its real job is the artifact: a
/// restyle is judged by looking at these, not by the pass mark.
///
/// `ImageRenderer` is not an option here: it never runs `onPreferenceChange`, so every measured
/// height comes out zero and the accordion renders as headers over empty bodies.
@Suite
@MainActor
struct RosterRenderTests {
    private let directory = URL(fileURLWithPath: "/tmp/herdling-render-\(UUID().uuidString)")

    @Test
    func rendersEverySurfaceInBothAppearances() async throws {
        print("Render artifacts: \(directory.path)")
        let store = await PreviewFixtures.loadedStore()
        defer { store.stop() }

        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            try render(
                AgentListView(store: store),
                size: NSSize(width: Theme.Size.panelWidth, height: 360),
                scheme: scheme,
                to: "quick-\(name)"
            )
            let muted = NavigationDestination.agent(sourceID: "local", sessionName: "default", paneID: "w1:genre-unit-validation")
            store.setObserveOnly(true, for: muted)
            try render(
                AgentListView(store: store),
                size: NSSize(width: Theme.Size.panelWidth, height: 360),
                scheme: scheme,
                to: "quick-muted-\(name)"
            )
            store.setObserveOnly(false, for: muted)
            let browser = NavigationBrowser(sources: store.sources)
            browser.setMode(.all)
            browser.toggleSource(SourceDescriptor.local.id)
            try render(
                AgentListView(store: store, browser: browser),
                size: NSSize(width: Theme.Size.panelWidth, height: 560),
                scheme: scheme,
                to: "all-\(name)"
            )
            try render(
                SessionRoster(store: store, source: .local, session: PreviewFixtures.nestedSession(),
                              branches: [:], showHeader: true, indent: 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .panelSurface(),
                size: NSSize(width: Theme.Size.panelWidth, height: 320),
                scheme: scheme,
                to: "nested-\(name)"
            )
            for application in TerminalApplication.allCases {
                store.setTerminalApplication(application)
                try render(
                    SettingsView(store: store),
                    size: NSSize(width: Theme.Size.settingsWidth, height: Theme.Size.settingsHeight),
                    scheme: scheme,
                    to: "settings-\(application.rawValue)-\(name)"
                )
            }
        }
    }

    // MARK: - Rendering

    private func render(
        _ view: some View,
        size: NSSize,
        scheme: ColorScheme,
        to name: String
    ) throws {
        // SwiftUI resolves its appearance from the application, not from the offscreen window, so
        // the process's own appearance is what has to move for a dark render to actually be dark.
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        app.appearance = appearance
        defer { app.appearance = previousAppearance }

        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        hosting.frame = NSRect(origin: .zero, size: size)
        // On the view as well as the app: an offscreen window has no screen to fall back on, so
        // without this the capture draws in aqua whatever the app's appearance says.
        hosting.appearance = appearance
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        // Behind everything and never activated: the layout has to happen, nothing has to be seen.
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        // Two runloop turns: the first lets SwiftUI install its observers, the second lets the
        // measurement they publish come back as state.
        for _ in 0..<2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // Saved expansion and the measured panel height can animate in successive turns.
        // Capture their settled geometry, not a half-clipped accordion.
        RunLoop.current.run(until: Date().addingTimeInterval(Theme.Duration.expand * 2))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            Issue.record("could not make a bitmap for \(name)")
            throw RenderFailure.noBitmap
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        #expect(rep.pixelsWide == Int(size.width * 2), "\(name) rendered at the wrong width")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode \(name) as PNG")
            throw RenderFailure.noPNG
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private enum RenderFailure: Error {
        case noBitmap
        case noPNG
    }
}
