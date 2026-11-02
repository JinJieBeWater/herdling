import AppKit
import SwiftUI

// MARK: - Sources

struct SourceOutline: View {
    let store: SessionStore
    let source: SourceInfo
    let isExpanded: Bool
    let onToggle: () -> Void

    private var counts: [AgentStatusCount] {
        AgentStatusCount.summarize(statuses: source.reportedStatuses)
    }

    private var summaryText: String {
        source.isAvailable ? (counts.isEmpty ? "no reported activity" : counts.primaryStatusText)
            : retryText ?? (isLoading ? "connecting" : "offline")
    }

    private var retryText: String? {
        (source.retryAt ?? source.core?.retryAt).map { "retry at \($0.formatted(date: .omitted, time: .standard))" }
    }

    private var accessibilitySummary: String {
        let counts = counts.statusCountsText
        guard !source.isAvailable else { return counts }
        return [summaryText, counts].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var isLoading: Bool { source.hasLegacy && !source.online && source.error == nil && source.core?.online != true }
    private var sourceKind: String {
        source.descriptor.isLocal ? "Local source" : source.descriptor.sshAlias == nil ? "Core machine" : "SSH source"
    }

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
                    if source.showsLegacy {
                        if source.core != nil { SpaceLabel(title: "Herdr") }
                        legacyRoster
                    }
                    if let core = source.core {
                        SpaceLabel(title: "Core")
                        if let error = core.error {
                            ErrorRow(message: error, retry: store.retryCore)
                        }
                        if core.terminals.isEmpty, core.online {
                            RosterEmptyState(symbol: "terminal", message: "No live terminals")
                        }
                        ForEach(core.terminals) { terminal in
                            CoreTerminalRow(store: store, terminal: terminal, enabled: core.online && terminal.online,
                                            statusError: core.error)
                        }
                    }
                    if !source.showsLegacy, source.core == nil {
                        RosterEmptyState(symbol: "terminal", message: "No running Herdr or Core instances")
                    }
                }
                .padding(.top, Theme.Spacing.sectionBodyGap)
            }
        }
    }

    @ViewBuilder private var legacyRoster: some View {
        if let error = source.error {
            ErrorRow(
                message: error,
                retry: source.descriptor.sshAlias == nil ? nil : {
                    store.retryRemoteSource(source.descriptor)
                }
            )
        } else if !source.online {
            // Keep the spinner in the shared glyph slot so the title aligns with other rows.
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
}

private struct CoreTerminalRow: View {
    let store: SessionStore
    let terminal: CoreTerminalInfo
    let enabled: Bool
    let statusError: String?

    private var destination: NavigationDestination { .coreTerminal(terminal.id) }
    private var statusText: String {
        if !enabled { return "unavailable" }
        if statusError != nil { return "Herdr App status unavailable" }
        return terminal.status?.rosterLabel ?? "no status report"
    }

    var body: some View {
        HoverRow(minHeight: Theme.Size.rowMinHeight, enabled: enabled,
                 accessibilityText: "\(terminal.title), \(statusText)",
                 action: { store.navigate(to: destination) }) { isHovered in
            HStack(spacing: Theme.Spacing.rowContentGap) {
                RowSymbol(symbol: terminal.status?.indicatorSymbolName ?? "terminal", tint: terminal.status?.badgeTint)
                Text(terminal.title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            NavigationRowFeedback(store: store, destination: destination, isHovered: isHovered)
            Color.clear.frame(width: Theme.Size.chevron)
        }
        .opacity(enabled ? 1 : 0.5)
        .navigationRow(.destination(destination))
        .help("\(terminal.title)\n\(statusText)\n\(destination.identityDescription)")
    }
}
