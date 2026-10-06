import AppKit
import SwiftUI

struct AgentListView: View {
    let store: SessionStore
    /// Opens the Settings window, which is its own window rather than a panel page.
    var onOpenSettings: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        AgentRoster(store: store, onOpenSettings: onOpenSettings)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelSurface()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .environment(\.panelIsOpen, store.panelOpen)
            .modifier(PanelHeightDriver(height: panelHeight))
            .onPreferenceChange(PanelContentHeightKey.self) { measurement in
                let height = measurement.total
                guard height > 0, abs(height - panelHeight) >= 0.5 else { return }
                if panelHeight == 0 || accessibilityReduceMotion {
                    panelHeight = height
                } else {
                    withAnimation(AccordionMotion.animation(reduceMotion: false)) {
                        panelHeight = height
                    }
                }
            }
    }
}

// MARK: - Roster

private struct AgentRoster: View {
    private enum ExpandedSection: Equatable {
        case recent
        case source(String)
    }

    let store: SessionStore
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var expandedSection: ExpandedSection?
    @State private var restoredExpansion = false
    @State private var now = Date()

    private var sourceIDs: [String] { store.sources.map(\.id) }

    /// Recent agents plus up to three of the most recently idle ones: attention items keep the
    /// section useful, the idle fill keeps its size predictable.
    private var recentItems: [RecentAgentItem] {
        let recent = store.recentAgents(at: now)
        var seen = Set(recent.map(\.id))
        return recent + store.recentFallbackAgents().filter { seen.insert($0.id).inserted }
    }

    private var effectiveExpandedSourceID: String? {
        guard case let .source(sourceID) = expandedSection,
              sourceIDs.contains(sourceID)
        else { return nil }
        return sourceID
    }

    private var isRecentExpanded: Bool { expandedSection == .recent }

    var body: some View {
        ScrollView {
            RosterContent(
                store: store,
                items: recentItems,
                isRecentExpanded: isRecentExpanded,
                toggleRecent: toggleRecent,
                isSourceExpanded: { source in source.id == effectiveExpandedSourceID },
                toggleSource: toggleSource
            )
        }
        .overflowFade()
        .scrollBounceBehavior(.basedOnSize)
        // The footer floats over the list as a transparent overlay, so rows pass beneath it and
        // dissolve rather than being cut off by a bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PanelFooter(store: store, onOpenSettings: onOpenSettings)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = .now
            }
        }
        .onChange(of: sourceIDs, initial: true) { _, ids in
            if !restoredExpansion {
                // Nothing to restore into until the sources have arrived: an empty first pass would
                // drop the saved section for good, and a cold launch would always open fully folded.
                guard !ids.isEmpty else { return }
                let savedSourceID = RosterLayout.expandedSourceID(
                    saved: store.expandedSourceID,
                    available: ids
                )
                expandedSection = savedSourceID.map(ExpandedSection.source)
                    ?? (store.expandedRecent ? .recent : nil)
                restoredExpansion = true
                return
            }

            if case let .source(sourceID) = expandedSection,
               !ids.contains(sourceID)
            {
                let replacement = ids.first.map(ExpandedSection.source)
                expandedSection = replacement
                persist(replacement)
            }
        }
    }

    private func toggleRecent() {
        let target: ExpandedSection? = isRecentExpanded ? nil : .recent
        persist(target)
        withAnimation(AccordionMotion.animation(reduceMotion: accessibilityReduceMotion)) {
            expandedSection = target
        }
    }

    private func toggleSource(_ sourceID: String) {
        let target: ExpandedSection? = sourceID == effectiveExpandedSourceID ? nil : .source(sourceID)
        persist(target)
        withAnimation(AccordionMotion.animation(reduceMotion: accessibilityReduceMotion)) {
            expandedSection = target
        }
    }

    private func persist(_ section: ExpandedSection?) {
        switch section {
        case .recent:
            store.expandedSourceID = ""
            store.expandedRecent = true
        case let .source(sourceID):
            store.expandedSourceID = sourceID
            store.expandedRecent = false
        case nil:
            store.expandedSourceID = ""
            store.expandedRecent = false
        }
    }
}

/// The roster itself, without the scroll view or the footer.
///
/// Split out so `AgentRoster` is only about *presenting* the roster — scrolling it, floating the
/// footer over it, folding groups — and this type is only about *what the roster is*. The content
/// also has to know its own height for the window, which is a property of the content, not of the
/// scroll view around it.
struct RosterContent: View {
    let store: SessionStore
    let items: [RecentAgentItem]
    let isRecentExpanded: Bool
    let toggleRecent: () -> Void
    let isSourceExpanded: (SourceInfo) -> Bool
    let toggleSource: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sectionSpacing) {
            if let error = store.focusError {
                ErrorRow(message: error, onDismiss: store.dismissFocusError)
            }
            RecentSection(
                store: store,
                items: items,
                isExpanded: isRecentExpanded,
                onToggle: toggleRecent
            )
            ForEach(store.sources) { source in
                SourceOutline(
                    store: store,
                    source: source,
                    isExpanded: isSourceExpanded(source),
                    onToggle: { toggleSource(source.id) }
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        // xs, not md: the fade is what separates the list from the footer, and this padding's only
        // other job is keeping the last row off the panel's edge. At md the void above the footer
        // read as half a missing row.
        .padding(.bottom, Theme.Spacing.xs)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PanelContentHeightKey.self,
                    value: PanelHeightMeasurement(body: geometry.size.height)
                )
            }
        }
    }
}
