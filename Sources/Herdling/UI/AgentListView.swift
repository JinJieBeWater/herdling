import AppKit
import SwiftUI

struct AgentListView: View {
    let store: SessionStore
    @State private var browser: NavigationBrowser

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var panelHeight: CGFloat = 0

    init(store: SessionStore, browser: NavigationBrowser? = nil) {
        self.store = store
        if let browser {
            _browser = State(initialValue: browser)
        } else {
            let model = NavigationBrowser(sources: store.sources)
            model.open(
                sources: store.sources,
                attempt: store.navigationAttempt,
                expandedSourceID: store.expandedSourceID
            )
            _browser = State(initialValue: model)
        }
    }

    var body: some View {
        NavigationPanel(store: store, browser: browser)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .panelSurface()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .environment(\.panelIsOpen, store.panelOpen)
            .environment(\.navigationBrowser, browser)
            .modifier(PanelHeightDriver(height: panelHeight))
            .onPreferenceChange(PanelContentHeightKey.self) { height in
                guard height > 0, abs(height - panelHeight) >= 0.5 else { return }
                if panelHeight == 0 || accessibilityReduceMotion {
                    panelHeight = height
                } else {
                    withAnimation(AccordionMotion.animation(reduceMotion: false)) {
                        panelHeight = height
                    }
                }
            }
            .onChange(of: browser.expandedSourceID) { _, sourceID in
                store.expandedSourceID = sourceID ?? ""
            }
    }
}
