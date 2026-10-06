import AppKit
import SwiftUI

// What sits inside a source: session, then Herdr space, then worktree, then agent. Each
// level only knows its own and hands the indent down.

struct SessionRoster: View {
    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let branches: [String: String]
    let showEmptyMain: Bool
    let showHeader: Bool
    let indent: CGFloat

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        branches: [String: String],
        showEmptyMain: Bool = true,
        showHeader: Bool,
        indent: CGFloat = 0
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.branches = branches
        self.showEmptyMain = showEmptyMain
        self.showHeader = showHeader
        self.indent = indent
    }

    private var summaryText: String {
        AgentStatusCount.summarize(session.agents).primaryStatusText
    }

    private var spaces: [RosterSpace] { RosterLayout.spaces(from: session.groups) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HoverRow(
                    minHeight: Theme.Size.rowMinHeight,
                    indent: indent,
                    enabled: session.online,
                    accessibilityText: "\(session.name), \(summaryText)",
                    action: { store.focusSession(session, source: source) }
                ) { _ in
                    RowSlot { EmptyView() }
                    Text(session.name)
                        .font(Theme.Typography.sectionHeader)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            if let error = session.error {
                ErrorRow(message: error)
            }

            if session.groups.isEmpty, session.online {
                Button { store.focusSession(session, source: source) } label: {
                    HStack(spacing: Theme.Spacing.lg) {
                        RowSlot { EmptyView() }
                        Label("Open \(session.name)", systemImage: "arrow.up.right")
                            .font(Theme.Typography.rowTrailing)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .padding(.leading, Theme.Spacing.md + indent)
                    .padding(.vertical, Theme.Spacing.sm)
                    .contentShape(Rectangle())
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
                        showEmptyMain: showEmptyMain,
                        indent: indent
                    )
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
    let showEmptyMain: Bool
    let indent: CGFloat

    init(
        store: SessionStore,
        source: SourceDescriptor,
        session: SessionInfo,
        space: RosterSpace,
        branches: [String: String],
        showEmptyMain: Bool,
        indent: CGFloat = 0
    ) {
        self.store = store
        self.source = source
        self.session = session
        self.space = space
        self.branches = branches
        self.showEmptyMain = showEmptyMain
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
        // With `showEmptyMain` off and nothing in the primary, there is no row to draw at all.
        return space.displayedWorktrees(showEmptyMain: showEmptyMain).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let collapsed = collapsesToItsAgents {
                // The same header row a worktree draws — same mark, same weight, same readout
                // column, and the same click: open this workspace in Ghostty. A header that looks
                // like the others but does nothing is worse than no header at all.
                let counts = AgentStatusCount.summarize(collapsed.group.agents)
                GroupHeaderRow(
                    leading: counts.first.map {
                        StatusIndicator(
                            symbol: $0.status.indicatorSymbolName,
                            tint: $0.status.badgeTint
                        )
                    } ?? StatusIndicator(symbol: "square.dashed", tint: nil),
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
                    enabled: session.online,
                    accessibilityLabel: space.name
                        + (counts.isEmpty ? "" : ", \(counts.primaryStatusText)")
                        + (store.isFocusing(collapsed.group, in: session, source: source) ? ", opening in Ghostty" : ""),
                    accessibilityHint: "Opens this group in Ghostty",
                    action: {
                        store.focusWorkspace(collapsed.group, in: session, source: source)
                    }
                ) {
                    GroupActivitySummary(counts: counts)
                    if store.isFocusing(collapsed.group, in: session, source: source) {
                        FocusIndicator(isPending: true, isHovered: false)
                    }
                }
                WorktreeAgents(
                    store: store,
                    source: source,
                    session: session,
                    group: collapsed.group,
                    indent: indent + WorktreeAgents.agentIndent
                )
            } else {
                // The space is the parent of the worktrees under it, so its label sits one step
                // left of their content: at the same x it would read as one more worktree.
                SpaceLabel(title: space.name, indent: indent)

                ForEach(space.displayedWorktrees(showEmptyMain: showEmptyMain)) { worktree in
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
        VStack(alignment: .leading, spacing: 0) {
            GroupHeaderRow(
                leading: counts.first.map {
                    StatusIndicator(symbol: $0.status.indicatorSymbolName, tint: $0.status.badgeTint)
                } ?? StatusIndicator(symbol: "square.dashed", tint: nil),
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
                action: { store.focusWorkspace(group, in: session, source: source) }
            ) {
                GroupActivitySummary(counts: counts)
                if isFocusPending {
                    FocusIndicator(isPending: true, isHovered: false)
                }
            }

            WorktreeAgents(
                store: store,
                source: source,
                session: session,
                group: group,
                indent: indent + WorktreeAgents.agentIndent
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isFocusPending: Bool { store.isFocusing(group, in: session, source: source) }
}

/// One worktree's agents, without the worktree's own heading row.
///
/// Shared by the two shapes a space takes: a heading followed by its agents, or — when the space
/// has nothing but `Main` — the agents alone under the space's header.
///
/// Agents sit one level below the row that heads them, and `agentIndent` keeps that step identical
/// for both shapes — so every agent title in the panel lands on the same x, and the indentation
/// still says which group a row belongs to.
struct WorktreeAgents: View {
    /// How far an agent row sits below the row that heads it.
    ///
    /// Two `indent`s, not one: a space header sits at the section's own indent while a worktree row
    /// already carries one `indent`, and this is what lands every agent row on the same x whichever
    /// kind of group it belongs to. One `indent` would put a collapsed space's agents at 6pt and a
    /// worktree's at 12pt — two columns for one list.
    static let agentIndent = Theme.Spacing.indent * 2

    let store: SessionStore
    let source: SourceDescriptor
    let session: SessionInfo
    let group: AgentGroup
    let indent: CGFloat

    var body: some View {
        ForEach(group.agents) { agent in
            AgentRow(
                agent: agent,
                enabled: session.online,
                isFocusPending: store.pendingFocusAgentID == RecentAgentItem.ID(
                    sourceID: source.id,
                    sessionName: session.name,
                    paneID: agent.paneID
                ),
                action: { store.focus(agent, in: session, source: source) },
                indent: indent
            )
        }
    }
}

struct AgentRow: View {
    let agent: AgentInfo
    let enabled: Bool
    let isFocusPending: Bool
    let action: () -> Void
    let indent: CGFloat

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
            StatusIndicator(symbol: agent.status.indicatorSymbolName, tint: agent.status.badgeTint)
            Text(agent.title)
                .font(Theme.Typography.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 0)

            FocusIndicator(isPending: isFocusPending, isHovered: isHovered)
            // The same slot a header reserves for its chevron, so the arrow and the summaries end
            // on one column instead of the arrow hanging 12pt further out.
            Color.clear.frame(width: Theme.Size.chevron)
        }
    }
}
