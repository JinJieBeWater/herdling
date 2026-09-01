import AppKit
import SwiftUI

struct AgentListView: View {
    let store: SessionStore
    let onHeightChange: (CGFloat) -> Void

    init(store: SessionStore, onHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.store = store
        self.onHeightChange = onHeightChange
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onPreferenceChange(PanelContentHeightKey.self) { measurement in
            if measurement.total > 0 { onHeightChange(measurement.total) }
        }
    }
}

private struct AgentRoster: View {
    let store: SessionStore
    @AppStorage("expanded.source") private var expandedSourceID = ""

    private var sourceIDs: [String] { store.sources.map(\.id) }
    private var effectiveExpandedSourceID: String? {
        RosterLayout.expandedSourceID(saved: expandedSourceID, available: sourceIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.focusError {
                        ErrorRow(message: error).padding(.bottom, 6)
                    }
                    ForEach(store.sources) { source in
                        SourceOutline(
                            store: store,
                            source: source,
                            isExpanded: source.id == effectiveExpandedSourceID,
                            onToggle: {
                                expandedSourceID = source.id == effectiveExpandedSourceID ? "" : source.id
                            }
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
        }
        .onChange(of: sourceIDs, initial: true) { _, ids in
            let validID = RosterLayout.expandedSourceID(saved: expandedSourceID, available: ids) ?? ""
            if expandedSourceID != validID {
                expandedSourceID = validID
            }
        }
    }
}

enum BranchSummary: Equatable {
    case single(String)
    case mixed
}

enum RosterLayout {
    static func expandedSourceID(saved: String, available: [String]) -> String? {
        guard !saved.isEmpty else { return nil }
        return available.contains(saved) ? saved : available.first
    }

    static func statusCounts(agents: [AgentInfo]) -> [AgentStatusCount] {
        AgentStatusCount.summarize(agents)
    }

    static func canFocusGroup(agents: [AgentInfo], sessionOnline: Bool) -> Bool {
        sessionOnline && !agents.isEmpty
    }

    static func groupHeaderHeight(branchSummary: BranchSummary?) -> CGFloat {
        branchSummary == nil ? 26 : 38
    }

    static func storageKey(_ prefix: String, components: [String]) -> String {
        prefix + "." + components.map { "\($0.utf8.count):\($0)" }.joined(separator: ":")
    }

    static func showsSessionHeader(name: String, sourceSessionCount: Int) -> Bool {
        sourceSessionCount > 1 || name != "default"
    }

    static func branchPaths(from spaces: [RosterSpace]) -> [String] {
        unique(spaces.flatMap(\.groups).flatMap(\.agents).map(\.cwd))
    }

    static func branchSummary(for agents: [AgentInfo], resolved: [String: String]) -> BranchSummary? {
        let branches = unique(agents.compactMap { resolved[$0.cwd] })
        guard let first = branches.first else { return nil }
        return branches.count == 1 ? .single(first) : .mixed
    }

    static func spaces(from groups: [AgentGroup]) -> [RosterSpace] {
        let names = Set(groups.map(\.name))
        var worktrees: [String: [AgentGroup]] = [:]
        var roots: [AgentGroup] = []

        for group in groups {
            if let parent = parentName(for: group.name, existingNames: names) {
                worktrees[parent, default: []].append(group)
            } else {
                roots.append(group)
            }
        }

        return roots.map { RosterSpace(primary: $0, worktrees: worktrees[$0.name] ?? []) }
    }

    private static func parentName(for name: String, existingNames: Set<String>) -> String? {
        for index in name.indices where name[index] == "/" {
            let prefix = String(name[..<index])
            if existingNames.contains(prefix) { return prefix }
        }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

struct RosterSpace: Identifiable, Sendable {
    var id: String { primary.id }
    var name: String { primary.name }
    var agents: [AgentInfo] { primary.agents + worktrees.flatMap(\.agents) }
    var groups: [AgentGroup] { [primary] + worktrees }

    let primary: AgentGroup
    let worktrees: [AgentGroup]

    var displayedWorktrees: [RosterWorktree] {
        (primary.agents.isEmpty ? [] : [RosterWorktree(name: "Main", group: primary)]) + worktrees.map {
            RosterWorktree(name: worktreeName($0), group: $0)
        }
    }

    func worktreeName(_ group: AgentGroup) -> String {
        String(group.name.dropFirst(name.count + 1))
    }
}

struct RosterWorktree: Identifiable, Sendable {
    var id: String { group.id }

    let name: String
    let group: AgentGroup
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
    let summary: GroupSummary
    let titleFont: Font
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(titleFont)
                        .lineLimit(1)
                    if let branchSummary { GitBranchLabel(summary: branchSummary) }
                }
                Spacer(minLength: 8)
                if summary.status == nil {
                    Text("No agents")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: summary.indicatorSymbolName)
                        .font(.system(size: 6, weight: .medium))
                        .foregroundStyle(summary.color)
                        .frame(width: 8, height: 16)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, branchSummary == nil ? 4 : 5)
            .frame(
                maxWidth: .infinity,
                minHeight: RosterLayout.groupHeaderHeight(branchSummary: branchSummary),
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(title), \(summary.text)")
        .background(
            Color.primary.opacity(isHovered && enabled ? 0.03 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered = enabled && $0 }
    }
}

private struct SourceSummary {
    let color: Color
    let text: String

    init(source: SourceInfo) {
        if !source.online {
            color = source.error == nil ? .secondary : .orange
            text = source.error == nil ? "connecting" : "offline"
            return
        }
        let summary = GroupSummary(agents: source.sessions.flatMap(\.agents))
        color = summary.color
        text = summary.text
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

private struct SourceStatusCounters: View {
    let counts: [AgentStatusCount]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(counts) { item in
                HStack(spacing: 2) {
                    StatusIndicator(symbol: item.status.indicatorSymbolName, color: item.status.color)
                    Text(item.count.formatted())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.count) \(item.status.rosterLabel)")
            }
        }
        .fixedSize()
    }
}

private struct SourceFocusRow: View {
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    private var summary: SourceSummary { SourceSummary(source: source) }
    private var counts: [AgentStatusCount] {
        RosterLayout.statusCounts(agents: source.sessions.flatMap(\.agents))
    }
    private var accessibilitySummary: String {
        counts.map { "\($0.count) \($0.status.rosterLabel)" }.joined(separator: ", ")
    }
    private var isLoading: Bool { !source.online && source.error == nil }
    private var kindLabel: String? { source.descriptor.sshAlias == nil ? nil : "SSH" }
    private var backgroundColor: Color { Color.primary.opacity(isHovered ? 0.07 : isExpanded ? 0.045 : 0.018) }
    private var railColor: Color { summary.color.opacity(isExpanded ? 1 : 0.55) }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(railColor)
                    .frame(width: 3, height: 18)
                    .accessibilityHidden(true)

                Image(systemName: source.descriptor.sshAlias == nil ? "desktopcomputer" : "network")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                Text(source.descriptor.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !counts.isEmpty {
                    SourceStatusCounters(counts: counts)
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text("Loading")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let kindLabel {
                    Text(kindLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(source.descriptor.name), \(accessibilitySummary.isEmpty ? summary.text : accessibilitySummary), \(isExpanded ? "expanded" : "collapsed")"
        )
        .padding(.trailing, 8)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

private struct SourceOutline: View {
    let store: SessionStore
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceFocusRow(
                source: source,
                isExpanded: isExpanded,
                onToggle: onToggle
            )

            if isExpanded {
                if let error = source.error {
                    ErrorRow(message: error).padding(.bottom, 14)
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
        .padding(.vertical, 2)
    }
}

private struct SessionRoster: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let branches: [String: String]
    let showHeader: Bool

    private var summary: GroupSummary { GroupSummary(agents: session.agents) }
    private var spaces: [RosterSpace] { RosterLayout.spaces(from: session.groups) }

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        branches: [String: String],
        showHeader: Bool
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.branches = branches
        self.showHeader = showHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HoverRow(
                    minHeight: 30,
                    enabled: session.online,
                    accessibilityText: "\(session.name), \(summary.text)",
                    action: { store.focusSession(session, source: source) }
                ) { _ in
                    Text(session.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: summary.indicatorSymbolName)
                        .font(.system(size: 6, weight: .medium))
                        .foregroundStyle(summary.color)
                        .frame(width: 8)
                        .accessibilityHidden(true)
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
                        branches: branches
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

    private var summary: GroupSummary { GroupSummary(agents: space.agents) }
    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        space: RosterSpace,
        branches: [String: String]
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.space = space
        self.branches = branches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(
                title: space.name,
                branchSummary: nil,
                summary: summary,
                titleFont: .system(size: 12.5, weight: .semibold),
                enabled: RosterLayout.canFocusGroup(
                    agents: space.agents,
                    sessionOnline: session.online
                ),
                action: focusSpace
            )

            ForEach(space.displayedWorktrees) { worktree in
                WorktreeSection(
                    store: store,
                    source: source,
                    session: session,
                    name: worktree.name,
                    group: worktree.group,
                    resolvedBranches: branches
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 6)
        .opacity(session.online ? 1 : 0.5)
    }

    private func focusSpace() {
        guard let agent = space.agents.first else { return }
        store.focus(agent, in: session, source: source)
    }
}

private struct WorktreeSection: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let name: String
    let group: AgentGroup
    let resolvedBranches: [String: String]

    private var summary: GroupSummary { GroupSummary(agents: group.agents) }
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
                summary: summary,
                titleFont: .system(size: 12, weight: .medium),
                enabled: RosterLayout.canFocusGroup(
                    agents: group.agents,
                    sessionOnline: session.online
                ),
                action: focusWorktree
            )

            ForEach(group.agents) { agent in
                AgentDetailRow(
                    agent: agent,
                    enabled: session.online,
                    action: { store.focus(agent, in: session, source: source) }
                )
            }
        }
        .padding(5)
        .background(
            Color.primary.opacity(0.026),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.top, 4)
    }

    private func focusWorktree() {
        guard let agent = group.agents.first else { return }
        store.focus(agent, in: session, source: source)
    }
}

private struct AgentDetailRow: View {
    let agent: AgentInfo
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HoverRow(
            minHeight: 26,
            enabled: enabled,
            accessibilityText: "\(agent.title), \(agent.status.rosterLabel)",
            action: action
        ) { isHovered in
            StatusIndicator(symbol: agent.status.indicatorSymbolName, color: agent.status.color)
            Text(agent.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 0.8 : 0)
                .accessibilityHidden(true)
        }
    }
}

private struct GroupSummary {
    let status: AgentStatus?

    init(agents: [AgentInfo]) {
        status = [.blocked, .working, .done, .idle, .unknown]
            .first { candidate in agents.contains { $0.status == candidate } }
    }

    var color: Color { status?.color ?? .secondary }

    var indicatorSymbolName: String { status?.indicatorSymbolName ?? "minus.circle" }

    var text: String {
        status?.rosterLabel ?? "stopped"
    }
}

private struct SettingsView: View {
    let store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button { store.setShowingSettings(false) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to agents")
                    .accessibilityLabel("Back to agents")
                    Spacer()
                    Text("Settings")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Color.clear.frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)
                .frame(height: 42)

                Divider()
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PanelContentHeightKey.self,
                        value: PanelHeightMeasurement(header: geometry.size.height)
                    )
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsGroup("SSH Sources") {
                        if store.availableSSHAliases.isEmpty {
                            Text("No aliases found in ~/.ssh/config").foregroundStyle(.secondary)
                        }
                        ForEach(store.availableSSHAliases, id: \.self) { alias in
                            Toggle(alias, isOn: Binding(
                                get: { store.selectedSSHAliases.contains(alias) },
                                set: { store.setRemoteAlias(alias, enabled: $0) }
                            ))
                        }
                    }

                    settingsGroup("General") {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                    }

                    settingsGroup("Permissions") {
                        permissionRow("Ghostty Automation", value: store.automationStatus)
                    }

                    if let error = store.settingsError { ErrorRow(message: error) }
                }
                .padding(16)
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity)
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
        .task { await store.refreshPermissionStatus() }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

struct PanelHeightMeasurement: Equatable {
    var header: CGFloat = 0
    var body: CGFloat = 0
    var total: CGFloat { header + body }
}

private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue = PanelHeightMeasurement()

    static func reduce(value: inout PanelHeightMeasurement, nextValue: () -> PanelHeightMeasurement) {
        let next = nextValue()
        value.header = max(value.header, next.header)
        value.body = max(value.body, next.body)
    }
}


private struct ErrorRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

extension AgentStatus {
    var indicatorSymbolName: String {
        switch self {
        case .blocked: "xmark.circle.fill"
        case .working: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    var rosterLabel: String {
        switch self {
        case .blocked: "needs you"
        case .done: "done"
        case .working: "working"
        case .idle: "ready"
        case .unknown: "unknown"
        }
    }

    var color: Color {
        switch self {
        case .blocked: Color(nsColor: StatusPalette.blocked)
        case .working: Color(nsColor: StatusPalette.working)
        case .done, .idle, .unknown: .secondary
        }
    }
}

enum StatusPalette {
    static let blocked = adaptive(
        light: (0.62, 0.08, 0.24),
        dark: (1.00, 0.38, 0.54)
    )
    static let done = adaptive(
        light: (0.06, 0.40, 0.18),
        dark: (0.32, 0.82, 0.51)
    )
    static let working = NSColor.controlAccentColor
    static let unknown = adaptive(
        light: (0.58, 0.30, 0.00),
        dark: (1.00, 0.66, 0.25)
    )

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }

    static func workingColor(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
        }
        return color
    }
}
