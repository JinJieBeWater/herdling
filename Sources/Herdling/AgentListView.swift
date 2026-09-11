import AppKit
import SwiftUI

private enum AccordionMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }
}

private struct DisclosureChevron: View {
    let isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .animation(AccordionMotion.animation(reduceMotion: accessibilityReduceMotion)) { image in
                image.rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

private struct AccordionHeader<Trailing: View>: View {
    let icon: String
    let iconHelp: String?
    let title: String
    let isExpanded: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void
    let trailing: () -> Trailing
    @State private var isHovered = false

    init(
        icon: String,
        iconHelp: String? = nil,
        title: String,
        isExpanded: Bool,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.iconHelp = iconHelp
        self.title = title
        self.isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                DisclosureChevron(isExpanded: isExpanded)
                iconView
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                trailing()
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .background {
            AccordionHeaderBackground(isExpanded: isExpanded, isHovered: isHovered)
        }
        .onHover { isHovered = $0 }
    }

    private var iconView: some View {
        let image = Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 16)
            .drawingGroup()
            .accessibilityHidden(true)
        return Group {
            if let iconHelp {
                image.help(iconHelp)
            } else {
                image
            }
        }
    }
}

private struct AccordionContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // max, not last-wins: the content's own default preference is reduced after the
        // measured background value and would otherwise overwrite it with 0.
        value = max(value, nextValue())
    }
}

private struct AccordionBody<Content: View>: View {
    let isExpanded: Bool
    let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var contentHeight: CGFloat = 0

    init(isExpanded: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AccordionContentHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(AccordionContentHeightKey.self) { contentHeight = $0 }
            .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(
                AccordionMotion.animation(reduceMotion: accessibilityReduceMotion),
                value: isExpanded
            )
    }
}

private struct PanelHeightDriver: GeometryEffect {
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

struct AgentListView: View {
    let store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var panelHeight: CGFloat = 0

    init(store: SessionStore) {
        self.store = store
    }

    var body: some View {
        Group {
            if store.showingSettings {
                SettingsView(store: store)
            } else {
                AgentRoster(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Fixed-size backdrop so the material never re-samples while the panel resizes.
            Rectangle()
                .fill(.regularMaterial)
                .frame(width: 640, height: 1200, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

private struct AgentRoster: View {
    private enum ExpandedSection: Equatable {
        case recent
        case source(String)
    }

    let store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("expanded.source") private var savedExpandedSourceID = ""
    @AppStorage("expanded.recent") private var savedRecentExpanded = true
    @State private var expandedSection: ExpandedSection?
    @State private var restoredExpansion = false
    @State private var now = Date()

    private var sourceIDs: [String] { store.sources.map(\.id) }
    private var effectiveExpandedSourceID: String? {
        guard case let .source(sourceID) = expandedSection,
              sourceIDs.contains(sourceID)
        else { return nil }
        return sourceID
    }
    private var isRecentExpanded: Bool {
        expandedSection == .recent
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.focusError {
                        ErrorRow(message: error, onDismiss: store.dismissFocusError)
                            .padding(.bottom, 6)
                    }
                    RecentSection(
                        store: store,
                        items: store.recentAgents(at: now),
                        isExpanded: isRecentExpanded,
                        onToggle: toggleRecent
                    )
                    ForEach(store.sources) { source in
                        SourceOutline(
                            store: store,
                            source: source,
                            isExpanded: source.id == effectiveExpandedSourceID,
                            onToggle: { toggleSource(source.id) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
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
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .contentMargins(.vertical, 8, for: .scrollIndicators)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = .now
            }
        }
        .onChange(of: sourceIDs, initial: true) { _, ids in
            if !restoredExpansion {
                let savedSourceID = RosterLayout.expandedSourceID(
                    saved: savedExpandedSourceID,
                    available: ids
                )
                expandedSection = savedSourceID.map(ExpandedSection.source)
                    ?? (savedRecentExpanded ? .recent : nil)
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
            savedExpandedSourceID = ""
            savedRecentExpanded = true
        case let .source(sourceID):
            savedExpandedSourceID = sourceID
            savedRecentExpanded = false
        case nil:
            savedExpandedSourceID = ""
            savedRecentExpanded = false
        }
    }
}

private struct RecentSection: View {
    let store: SessionStore
    let items: [RecentAgentItem]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var outlineSources: [SourceInfo] {
        RecentAgentList.outlineSources(from: store.sources, items: items)
    }

    var body: some View {
        if !items.isEmpty {
            Section {
                AccordionBody(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        let sources = outlineSources
                        ForEach(sources) { source in
                            let showsSource = sources.count > 1 || source.descriptor.sshAlias != nil

                            if showsSource {
                                RecentSourceHeader(source: source)
                            }

                            ForEach(source.sessions) { session in
                                SessionRoster(
                                    store: store,
                                    source: source.descriptor,
                                    session: session,
                                    branches: source.branches,
                                    showEmptyMain: false,
                                    showHeader: RosterLayout.showsSessionHeader(
                                        name: session.name,
                                        sourceSessionCount: source.sessions.count
                                    )
                                )
                                .padding(.leading, showsSource ? 14 : 0)
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            } header: {
                AccordionHeader(
                    icon: "clock",
                    title: "Recent",
                    isExpanded: isExpanded,
                    accessibilityLabel: "Recent, \(isExpanded ? "expanded" : "collapsed")",
                    accessibilityHint: "Expands or collapses recent agents",
                    action: onToggle
                ) {
                    Spacer(minLength: 8)
                    GroupActivitySummary(counts: AgentStatusCount.summarize(items.map(\.agent)))
                }
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
        }
    }
}

private struct RecentSourceHeader: View {
    let source: SourceInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source.descriptor.sshAlias == nil ? "desktopcomputer" : "network")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(source.descriptor.name)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            GroupActivitySummary(counts: AgentStatusCount.summarize(source.sessions.flatMap(\.agents)))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct GitBranchLabel: View {
    let summary: BranchSummary

    private var text: String {
        switch summary {
        case let .single(branch): branch
        case .mixed: "mixed"
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(summary == .mixed ? "Multiple branches" : text)
    }
}

private struct HoverRow<Content: View>: View {
    let minHeight: CGFloat
    let enabled: Bool
    let accessibilityText: String
    let action: () -> Void
    let content: (Bool) -> Content
    @State private var isHovered = false

    init(
        minHeight: CGFloat = 26,
        enabled: Bool = true,
        accessibilityText: String,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.minHeight = minHeight
        self.enabled = enabled
        self.accessibilityText = accessibilityText
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content(isHovered) }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens this item in Ghostty")
        .background(
            Color.primary.opacity(isHovered ? 0.04 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered = $0 }
    }
}

private struct GroupHeader: View {
    let title: String
    let branchSummary: BranchSummary?
    let counts: [AgentStatusCount]
    let titleFont: Font
    let enabled: Bool
    let isFocusPending: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(
            minHeight: RosterLayout.groupHeaderHeight(branchSummary: branchSummary),
            enabled: enabled,
            accessibilityText: title + (counts.isEmpty ? "" : ", \(counts.primaryStatusText)") + (isFocusPending ? ", opening in Ghostty" : ""),
            action: action
        ) { _ in
            HStack(alignment: .top, spacing: 8) {
                if let primary = counts.first {
                    StatusIndicator(
                        symbol: primary.status.indicatorSymbolName,
                        color: primary.status.color
                    )
                    .padding(.top, 3)
                } else {
                    StatusIndicator(symbol: "square.dashed", color: .secondary)
                        .padding(.top, 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(titleFont)
                        .lineLimit(1)
                    if let branchSummary { GitBranchLabel(summary: branchSummary) }
                }
                Spacer(minLength: 8)
                if !counts.isEmpty {
                    GroupActivitySummary(counts: counts)
                }
                if isFocusPending {
                    FocusIndicator(isPending: true, isHovered: false)
                }
            }
            .padding(.vertical, branchSummary == nil ? 4 : 5)
        }
        .accessibilityHint("Opens this group in Ghostty")
    }
}

private struct SpaceLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
    }
}

private struct GroupActivitySummary: View {
    let counts: [AgentStatusCount]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(counts) { count in
                Text("\(count.count) \(count.status.rawValue)")
                    .foregroundStyle(count.status.color)
            }
        }
        .font(.system(size: 11))
        .fixedSize()
        .frame(minWidth: 140, alignment: .trailing)
        .layoutPriority(1)
    }
}

private extension Collection where Element == AgentStatusCount {
    var primaryStatusText: String { first?.status.rosterLabel ?? "stopped" }
}

private struct AccordionHeaderBackground: View {
    let isExpanded: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.07 : isExpanded ? 0.025 : 0))
    }
}

private struct StatusIndicator: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 10)
            .accessibilityHidden(true)
    }
}

private struct SourceFocusRow: View {
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    private var counts: [AgentStatusCount] {
        AgentStatusCount.summarize(source.sessions.flatMap(\.agents))
    }
    private var retryText: String? {
        source.retryAt.map { "retry at \($0.formatted(date: .omitted, time: .standard))" }
    }
    private var summaryText: String {
        source.online ? counts.primaryStatusText : retryText ?? (source.error == nil ? "connecting" : "offline")
    }
    private var accessibilitySummary: String {
        let counts = counts.map { "\($0.count) \($0.status.rosterLabel)" }.joined(separator: ", ")
        guard !source.online else { return counts }
        return [summaryText, counts].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private var isLoading: Bool { !source.online && source.error == nil }
    private var sourceKind: String { source.descriptor.sshAlias == nil ? "Local source" : "SSH source" }
    var body: some View {
        AccordionHeader(
            icon: source.descriptor.sshAlias == nil ? "desktopcomputer" : "network",
            iconHelp: sourceKind,
            title: source.descriptor.name,
            isExpanded: isExpanded,
            accessibilityLabel: "\(source.descriptor.name), \(sourceKind), \(accessibilitySummary.isEmpty ? summaryText : accessibilitySummary), \(isExpanded ? "expanded" : "collapsed")",
            accessibilityHint: "Expands or collapses this source",
            action: onToggle
        ) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .progressViewStyle(.circular)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(source.retryAt == nil ? "Loading" : "Retrying")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let retryAt = source.retryAt {
                Text("Retry \(retryAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !counts.isEmpty {
                GroupActivitySummary(counts: counts)
            }
        }
    }
}

private struct SourceOutline: View {
    let store: SessionStore
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Section {
            AccordionBody(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = source.error {
                        ErrorRow(message: error)
                        if source.descriptor.sshAlias != nil {
                            Button("Retry now") {
                                store.retryRemoteSource(source.descriptor)
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.link)
                            .padding(.leading, 26)
                            .padding(.bottom, 14)
                            .accessibilityHint("Retries this SSH source immediately")
                        }
                    } else if !source.online {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(.circular)
                            Text("Loading sessions and branches…")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                        .padding(.vertical, 8)
                        .padding(.bottom, 6)
                    } else if source.sessions.isEmpty {
                        Text("No running sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 14)
                    }

                    ForEach(source.sessions) { session in
                        SessionRoster(
                            store: store,
                            source: source.descriptor,
                            session: session,
                            branches: source.branches,
                            showHeader: RosterLayout.showsSessionHeader(
                                name: session.name,
                                sourceSessionCount: source.sessions.count
                            )
                        )
                    }
                }
            }
            .padding(.bottom, 2)
        } header: {
            SourceFocusRow(
                source: source,
                isExpanded: isExpanded,
                onToggle: onToggle
            )
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }
}

private struct SessionRoster: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let branches: [String: String]
    let showEmptyMain: Bool
    let showHeader: Bool

    private var summaryText: String {
        AgentStatusCount.summarize(session.agents).primaryStatusText
    }
    private var spaces: [RosterSpace] { RosterLayout.spaces(from: session.groups) }

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        branches: [String: String],
        showEmptyMain: Bool = true,
        showHeader: Bool
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.branches = branches
        self.showEmptyMain = showEmptyMain
        self.showHeader = showHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HoverRow(
                    minHeight: 30,
                    enabled: session.online,
                    accessibilityText: "\(session.name), \(summaryText)",
                    action: { store.focusSession(session, source: source) }
                ) { _ in
                    Text(session.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            if let error = session.error {
                ErrorRow(message: error)
            }

            if session.groups.isEmpty, session.online {
                Button { store.focusSession(session, source: source) } label: {
                    Label("Open \(session.name)", systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(spaces) { space in
                    SpaceSection(
                        store: store,
                        source: source,
                        session: session,
                        space: space,
                        branches: branches,
                        showEmptyMain: showEmptyMain
                    )
                }
            }
        }
    }
}

private struct SpaceSection: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let space: RosterSpace
    let branches: [String: String]
    let showEmptyMain: Bool

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        space: RosterSpace,
        branches: [String: String],
        showEmptyMain: Bool
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.space = space
        self.branches = branches
        self.showEmptyMain = showEmptyMain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceLabel(title: space.name)

            ForEach(space.displayedWorktrees(showEmptyMain: showEmptyMain)) { worktree in
                WorktreeSection(
                    store: store,
                    source: source,
                    session: session,
                    name: worktree.name,
                    group: worktree.group,
                    resolvedBranches: branches
                )
                .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .opacity(session.online ? 1 : 0.5)
    }
}

private struct WorktreeSection: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let name: String
    let group: AgentGroup
    let resolvedBranches: [String: String]

    private var counts: [AgentStatusCount] { AgentStatusCount.summarize(group.agents) }
    private var branchSummary: BranchSummary? {
        RosterLayout.branchSummary(for: group.agents, resolved: resolvedBranches)
    }

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        name: String,
        group: AgentGroup,
        resolvedBranches: [String: String]
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.name = name
        self.group = group
        self.resolvedBranches = resolvedBranches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(
                title: name,
                branchSummary: branchSummary,
                counts: counts,
                titleFont: .system(size: 12.5, weight: .semibold),
                enabled: session.online,
                isFocusPending: store.pendingFocusWorkspaceID == SessionStore.WorkspaceFocusID(
                    sourceID: source.id,
                    sessionName: session.name,
                    workspaceID: group.id
                ),
                action: { store.focusWorkspace(group, in: session, source: source) }
            )

            ForEach(group.agents) { agent in
                AgentDetailRow(
                    agent: agent,
                    enabled: session.online,
                    isFocusPending: store.pendingFocusAgentID == RecentAgentItem.ID(
                        sourceID: source.id,
                        sessionName: session.name,
                        paneID: agent.paneID
                    ),
                    action: { store.focus(agent, in: session, source: source) }
                )
                .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .background(
            Color.primary.opacity(0.018),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.top, 3)
    }

}

private struct AgentDetailRow: View {
    let agent: AgentInfo
    let enabled: Bool
    let isFocusPending: Bool
    let action: () -> Void

    private var accessibilityText: String {
        let base = "\(agent.title), \(agent.status.rosterLabel)"
        return base + (isFocusPending ? ", opening in Ghostty" : "")
    }

    var body: some View {
        HoverRow(
            minHeight: 24,
            enabled: enabled,
            accessibilityText: accessibilityText,
            action: action
        ) { isHovered in
            StatusIndicator(symbol: agent.status.indicatorSymbolName, color: agent.status.color)
            Text(agent.title)
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer(minLength: 0)

            FocusIndicator(isPending: isFocusPending, isHovered: isHovered)
        }
    }
}

private struct FocusIndicator: View {
    let isPending: Bool
    let isHovered: Bool

    var body: some View {
        if isPending {
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.circular)
                .tint(.secondary)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 0.8 : 0)
                .accessibilityHidden(true)
        }
    }
}

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
