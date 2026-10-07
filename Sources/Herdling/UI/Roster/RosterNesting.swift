import AppKit
import SwiftUI

// What sits inside a source: session, then Herdr space, then worktree, then agent. Each
// level only knows its own and hands the indent down.

struct SessionRoster: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let branches: [String: String]
    let showHeader: Bool
    let indent: CGFloat

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        branches: [String: String],
        showHeader: Bool,
        indent: CGFloat = 0
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.branches = branches
        self.showHeader = showHeader
        self.indent = indent
    }

    private var summaryText: String {
        AgentStatusCount.summarize(session.agents).primaryStatusText
    }

    private var spaces: [RosterSpace] { RosterLayout.spaces(from: session.groups) }
    private var contentIndent: CGFloat { indent + (showHeader ? Theme.Spacing.indent : 0) }
    private var destination: NavigationDestination { .session(sourceID: source.id, sessionName: session.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            if showHeader {
                HoverRow(
                    minHeight: Theme.Size.rowMinHeight,
                    indent: indent,
                    enabled: session.online,
                    accessibilityText: "\(session.name), \(summaryText)",
                    action: { store.navigate(to: destination) }
                ) { isHovered in
                    HStack(spacing: Theme.Spacing.rowContentGap) {
                        RowSlot { EmptyView() }
                        Text(session.name)
                            .font(Theme.Typography.sectionHeader)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Spacing.md)
                    NavigationRowFeedback(store: store, destination: destination, isHovered: isHovered, showsIdleArrow: false)
                }
                .navigationRow(.destination(destination))
            }

            if !session.groups.isEmpty || session.error != nil || (!showHeader && session.online) {
                VStack(alignment: .leading, spacing: Theme.Spacing.groupGap) {
                    if let error = session.error {
                        ErrorRow(message: error, indent: contentIndent)
                    }

                    if session.groups.isEmpty, session.online, !showHeader {
                        HoverRow(
                            indent: contentIndent,
                            accessibilityText: "Open \(session.name)",
                            action: { store.navigate(to: destination) }
                        ) { isHovered in
                            HStack(spacing: Theme.Spacing.rowContentGap) {
                                RowSlot { EmptyView() }
                                Label("Open \(session.name)", systemImage: "arrow.up.right")
                                    .font(Theme.Typography.rowTrailing)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            Spacer(minLength: Theme.Spacing.md)
                            NavigationRowFeedback(store: store, destination: destination, isHovered: isHovered, showsIdleArrow: false)
                        }
                        .navigationRow(.destination(destination))
                    } else {
                        ForEach(spaces) { space in
                            SpaceSection(
                                store: store,
                                source: source,
                                session: session,
                                space: space,
                                branches: branches,
                                indent: contentIndent
                            )
                        }
                    }
                }
            }
        }
    }
}

struct SpaceSection: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let space: RosterSpace
    let branches: [String: String]
    let indent: CGFloat

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        space: RosterSpace,
        branches: [String: String],
        indent: CGFloat = 0
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.space = space
        self.branches = branches
        self.indent = indent
    }

    /// Herdr gives every workspace a worktree called `Main`, so a space with no branches shows the
    /// same row under every label. When that is the only worktree, the row says nothing the label
    /// does not, so it is not drawn: the label becomes the group's header instead — same mark, same
    /// title weight, same readout column — and the agents sit one indent below it.
    ///
    /// A space that has branches keeps its quiet label, because there the label heads *worktree
    /// rows* rather than agents. Bold means "this heads agents directly".
    private var collapsesToItsAgents: RosterWorktree? {
        guard space.isOnlyItsPrimaryWorktree else { return nil }
        return space.displayedWorktrees().first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            if let collapsed = collapsesToItsAgents {
                // The same header row a worktree draws — same mark, same weight, same readout
                // column, and the same click: open this workspace in Ghostty. A header that looks
                // like the others but does nothing is worse than no header at all.
                let counts = AgentStatusCount.summarize(collapsed.group.agents)
                GroupHeaderRow(
                    leading: counts.first.map {
                        RowSymbol(
                            symbol: $0.status.indicatorSymbolName,
                            tint: $0.status.badgeTint
                        )
                    } ?? RowSymbol(symbol: "square.dashed", tint: nil),
                    title: space.name,
                    titleFont: .body.weight(.medium),
                    subtitle: {
                        if let branch = RosterLayout.branchSummary(
                            for: collapsed.group.agents,
                            resolved: branches
                        ) {
                            GitBranchLabel(summary: branch)
                        }
                    },
                    isExpanded: nil,
                    indent: indent,
                    enabled: session.online,
                    accessibilityLabel: space.name
                        + (counts.isEmpty ? "" : ", \(counts.primaryStatusText)")
                        + (store.isFocusing(collapsed.group, in: session, source: source) ? ", opening in Ghostty" : ""),
                    accessibilityHint: "Opens this group in Ghostty",
                    action: {
                        store.navigate(to: .workspace(sourceID: source.id, sessionName: session.name, workspaceID: collapsed.group.id))
                    }
                ) {
                    GroupActivitySummary(counts: counts)
                    NavigationRowFeedback(
                        store: store,
                        destination: .workspace(sourceID: source.id, sessionName: session.name, workspaceID: collapsed.group.id),
                        fallbackPending: store.isFocusing(collapsed.group, in: session, source: source),
                        showsIdleArrow: false
                    )
                }
                .navigationRow(.destination(.workspace(sourceID: source.id, sessionName: session.name, workspaceID: collapsed.group.id)))
                if !collapsed.group.agents.isEmpty {
                    WorktreeAgents(
                        store: store,
                        source: source,
                        session: session,
                        group: collapsed.group,
                        indent: indent + Theme.Spacing.indent
                    )
                }
            } else {
                // The space is the parent of the worktrees under it, so its label sits one step
                // left of their content: at the same x it would read as one more worktree.
                SpaceLabel(title: space.name, indent: indent)

                VStack(alignment: .leading, spacing: Theme.Spacing.groupGap) {
                    ForEach(space.displayedWorktrees()) { worktree in
                        WorktreeSection(
                            store: store,
                            source: source,
                            session: session,
                            name: worktree.name,
                            group: worktree.group,
                            resolvedBranches: branches,
                            indent: indent + Theme.Spacing.indent
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .opacity(session.online ? 1 : 0.5)
    }
}

struct WorktreeSection: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let name: String
    let group: AgentGroup
    let resolvedBranches: [String: String]
    let indent: CGFloat

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        name: String,
        group: AgentGroup,
        resolvedBranches: [String: String],
        indent: CGFloat = 0
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.name = name
        self.group = group
        self.resolvedBranches = resolvedBranches
        self.indent = indent
    }

    private var counts: [AgentStatusCount] { AgentStatusCount.summarize(group.agents) }

    private var branchSummary: BranchSummary? {
        RosterLayout.branchSummary(for: group.agents, resolved: resolvedBranches)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            GroupHeaderRow(
                leading: counts.first.map {
                    RowSymbol(symbol: $0.status.indicatorSymbolName, tint: $0.status.badgeTint)
                } ?? RowSymbol(symbol: "square.dashed", tint: nil),
                title: name,
                titleFont: .body.weight(.medium),
                subtitle: {
                    if let branch = branchSummary {
                        GitBranchLabel(summary: branch)
                    }
                },
                indent: indent,
                enabled: session.online,
                accessibilityLabel: name
                    + (counts.isEmpty ? "" : ", \(counts.primaryStatusText)")
                    + (isFocusPending ? ", opening in Ghostty" : ""),
                accessibilityHint: "Opens this group in Ghostty",
                action: { store.navigate(to: destination) }
            ) {
                GroupActivitySummary(counts: counts)
                NavigationRowFeedback(store: store, destination: destination, fallbackPending: isFocusPending, showsIdleArrow: false)
            }
            .navigationRow(.destination(destination))

            if !group.agents.isEmpty {
                WorktreeAgents(
                    store: store,
                    source: source,
                    session: session,
                    group: group,
                    indent: indent + Theme.Spacing.indent
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isFocusPending: Bool { store.isFocusing(group, in: session, source: source) }
    private var destination: NavigationDestination { .workspace(sourceID: source.id, sessionName: session.name, workspaceID: group.id) }
}

/// One worktree's agents, without the worktree's own heading row.
///
/// Shared by the two shapes a space takes: a heading followed by its agents, or — when the space
/// has nothing but `Main` — the agents alone under the space's header.
///
/// The caller adds one indent from the visible parent, including when Main is omitted.
struct WorktreeAgents: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let group: AgentGroup
    let indent: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            ForEach(group.agents) { agent in
                let destination = NavigationDestination.agent(sourceID: source.id, sessionName: session.name, paneID: agent.paneID)
                AgentRow(
                    agent: agent,
                    enabled: session.online,
                    isFocusPending: store.pendingFocusAgentID == AgentFocusID(
                        sourceID: source.id,
                        sessionName: session.name,
                        paneID: agent.paneID
                    ),
                    action: { store.navigate(to: destination) },
                    indent: indent,
                    store: store,
                    destination: destination
                )
                .navigationRow(.destination(destination))
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentInfo
    let enabled: Bool
    let isFocusPending: Bool
    let action: () -> Void
    let indent: CGFloat
    var store: SessionStore? = nil
    var destination: NavigationDestination? = nil

    private var accessibilityText: String {
        let base = "\(agent.title), \(agent.status.rosterLabel)"
        return base + (isFocusPending ? ", opening in Ghostty" : "")
    }

    var body: some View {
        HoverRow(
            minHeight: Theme.Size.rowMinHeight,
            indent: indent,
            enabled: enabled,
            accessibilityText: accessibilityText,
            action: action
        ) { isHovered in
            HStack(spacing: Theme.Spacing.rowContentGap) {
                RowSymbol(symbol: agent.status.indicatorSymbolName, tint: agent.status.badgeTint)
                Text(agent.title)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if let store, let destination {
                NavigationRowFeedback(store: store, destination: destination, fallbackPending: isFocusPending, isHovered: isHovered)
            } else {
                FocusIndicator(isPending: isFocusPending, isHovered: isHovered)
            }
            // The same slot a header reserves for its chevron, so the arrow and the summaries end
            // on one column instead of the arrow hanging 12pt further out.
            Color.clear.frame(width: Theme.Size.chevron)
        }
    }
}
