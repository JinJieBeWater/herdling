import AppKit
import SwiftUI

struct AgentListView: View {
    let store: SessionStore
    let showAgentActions: (@MainActor (NavigationDestination) -> Void)?
    @State private var browser: NavigationBrowser

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var panelHeight: CGFloat = 0

    init(store: SessionStore, browser: NavigationBrowser? = nil,
         showAgentActions: (@MainActor (NavigationDestination) -> Void)? = nil) {
        self.store = store
        self.showAgentActions = showAgentActions
        if let browser {
            _browser = State(initialValue: browser)
        } else {
            let model = NavigationBrowser(sources: store.sources)
            model.open(
                sources: store.sources,
                attempt: store.navigationAttempt, keyboard: false,
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
            .environment(\.showAgentActions, showAgentActions)
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
