import AppKit
import SwiftUI

// The two top-level groups of the roster: Recent, and one per source. Both are an
// accordion header plus a body.

struct RecentSection: View {
    let store: SessionStore
    let items: [RecentAgentItem]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var outlineSources: [SourceInfo] {
        RecentAgentList.outlineSources(from: store.sources, items: items)
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupHeaderRow(
                leading: RosterTile(symbol: "clock", tint: Theme.Hue.indigo),
                title: "Recent",
                isExpanded: isExpanded,
                accessibilityLabel: "Recent, \(isExpanded ? "expanded" : "collapsed")",
                accessibilityHint: "Expands or collapses recent agents",
                action: onToggle
            ) {
                GroupActivitySummary(counts: AgentStatusCount.summarize(items.map(\.agent)))
            }

            AccordionBody(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    // The section stays put when nothing is recent, with the same empty row a
                    // source shows, so the panel keeps its shape instead of dropping a group.
                    if items.isEmpty {
                        RosterEmptyState(symbol: "clock", message: "No recent activity")
                    } else {
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
                                    ),
                                    indent: showsSource ? Theme.Spacing.sm : 0
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, Theme.Spacing.sm)
            }
        }
    }
}

/// A source's own label inside Recent: quieter than a section header, because it is a caption for
/// the rows under it rather than a group of its own.
struct RecentSourceHeader: View {
    let source: SourceInfo

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            RosterTile(
                symbol: source.rosterSymbol,
                tint: source.rosterTint
            )
            Text(source.descriptor.name)
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            GroupActivitySummary(counts: AgentStatusCount.summarize(source.sessions.flatMap(\.agents)))
            // The chevron slot, reserved here too: every header's readout ends on one column.
            Color.clear.frame(width: Theme.Size.chevron)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sources

struct SourceOutline: View {
    let store: SessionStore
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    private var counts: [AgentStatusCount] {
        AgentStatusCount.summarize(source.sessions.flatMap(\.agents))
    }

    private var summaryText: String {
        source.online ? counts.primaryStatusText : retryText ?? (source.error == nil ? "connecting" : "offline")
    }

    private var retryText: String? {
        source.retryAt.map { "retry at \($0.formatted(date: .omitted, time: .standard))" }
    }

    private var accessibilitySummary: String {
        let counts = counts.map { "\($0.count) \($0.status.rosterLabel)" }.joined(separator: ", ")
        guard !source.online else { return counts }
        return [summaryText, counts].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var isLoading: Bool { !source.online && source.error == nil }
    private var sourceKind: String { source.descriptor.sshAlias == nil ? "Local source" : "SSH source" }

    var body: some View {
        VStack(spacing: 0) {
            GroupHeaderRow(
                leading: RosterTile(
                    symbol: source.rosterSymbol,
                    tint: source.rosterTint
                )
                .help(sourceKind),
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
                        .frame(
                            width: Theme.Size.progressIndicator,
                            height: Theme.Size.progressIndicator
                        )
                        .accessibilityHidden(true)
                    Text(source.retryAt == nil ? "Loading" : "Retrying")
                        .font(Theme.Typography.groupLabel)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else if let retryAt = source.retryAt {
                    Text("Retry \(retryAt.formatted(date: .omitted, time: .standard))")
                        .font(Theme.Typography.groupLabel)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                GroupActivitySummary(counts: counts)
            }

            AccordionBody(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = source.error {
                        ErrorRow(
                            message: error,
                            retry: source.descriptor.sshAlias == nil ? nil : {
                                store.retryRemoteSource(source.descriptor)
                            }
                        )
                    } else if !source.online {
                        // The same row grammar as everything else: the spinner sits in the shared
                        // glyph slot so the sentence lands on the rows' title column.
                        HStack(spacing: Theme.Spacing.lg) {
                            ProgressView()
                                .controlSize(.mini)
                                .progressViewStyle(.circular)
                                .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
                                .accessibilityHidden(true)
                            Text("Loading sessions and branches…")
                                .font(Theme.Typography.rowTrailing)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.rowVertical)
                    } else if source.sessions.isEmpty {
                        RosterEmptyState(
                            symbol: source.rosterSymbol,
                            message: "No running sessions"
                        )
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
                .padding(.bottom, Theme.Spacing.sm)
            }
        }
    }
}
