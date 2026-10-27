import AppKit
import SwiftUI

// MARK: - Sources

struct SourceOutline: View {
    let store: SessionStore
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    private var counts: [AgentStatusCount] {
        let counts = source.sessions.flatMap { store.statusCounts($0.agents, sourceID: source.id, sessionName: $0.name) }
        return [AgentStatus.blocked, .done, .working, .idle, .unknown].compactMap { status in
            let count = counts.filter { $0.status == status }.reduce(0) { $0 + $1.count }
            return count == 0 ? nil : AgentStatusCount(status: status, count: count)
        }
    }

    private var summaryText: String {
        source.online ? counts.primaryStatusText : retryText ?? (source.error == nil ? "connecting" : "offline")
    }

    private var retryText: String? {
        source.retryAt.map { "retry at \($0.formatted(date: .omitted, time: .standard))" }
    }

    private var accessibilitySummary: String {
        let counts = counts.statusCountsText
        guard !source.online else { return counts }
        return [summaryText, counts].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var isLoading: Bool { !source.online && source.error == nil }
    private var sourceKind: String { source.descriptor.sshAlias == nil ? "Local source" : "SSH source" }

    var body: some View {
        VStack(spacing: 0) {
            GroupHeaderRow(
                leading: RowSymbol(
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
                if !counts.isEmpty {
                    GroupActivitySummary(counts: counts)
                }
            }
            .navigationRow(.source(source.id))

            AccordionBody(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: Theme.Spacing.groupGap) {
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
                        HStack(spacing: Theme.Spacing.rowContentGap) {
                            ProgressView()
                                .controlSize(.mini)
                                .progressViewStyle(.circular)
                                .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
                                .accessibilityHidden(true)
                            Text("Loading sessions and branches…")
                                .font(Theme.Typography.rowTrailing)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .padding(.horizontal, Theme.Spacing.rowHorizontal)
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
                .padding(.top, Theme.Spacing.sectionBodyGap)
            }
        }
    }
}
