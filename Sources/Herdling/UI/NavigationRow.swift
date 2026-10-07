import SwiftUI

extension EnvironmentValues {
    @Entry var navigationBrowser: NavigationBrowser? = nil
    @Entry var navigationRowID: NavigationRowID? = nil
}

extension View {
    /// Attach identity to the actionable row, never to its surrounding subtree.
    func navigationRow(_ id: NavigationRowID) -> some View {
        modifier(NavigationRowIdentity(id: id))
    }
}

private struct NavigationRowIdentity: ViewModifier {
    let id: NavigationRowID
    @Environment(\.navigationBrowser) private var browser

    func body(content: Content) -> some View {
        content
            .environment(\.navigationRowID, id)
            .id(id)
            .help(help)
            .accessibilityHint(help)
    }

    private var help: String {
        guard case let .destination(destination) = id else { return "Expands or collapses this source" }
        let presentation = browser?.presentation(for: destination)
        let reason = browser?.attempt.flatMap { attempt in
            attempt.destination == destination && attempt.phase == .failed ? attempt.message : nil
        }
        let identity: String
        switch destination {
        case let .agent(sourceID, sessionName, paneID):
            identity = "Source \(sourceID), session \(sessionName), pane \(paneID)"
        case let .workspace(sourceID, sessionName, workspaceID):
            identity = "Source \(sourceID), session \(sessionName), workspace \(workspaceID)"
        case let .session(sourceID, sessionName):
            identity = "Source \(sourceID), session \(sessionName)"
        }
        return ["Opens this item in Ghostty", presentation?.title, presentation?.subtitle, identity, reason].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Shared trailing feedback for direct agent, workspace and session targets.
struct NavigationRowFeedback: View {
    let store: SessionStore
    let destination: NavigationDestination
    var fallbackPending = false
    var isHovered = false
    var showsIdleArrow = true
    @Environment(\.navigationBrowser) private var browser

    var body: some View {
        if let attempt = browser?.attempt, attempt.destination == destination {
            switch attempt.phase {
            case .failed:
                RosterActionPill(title: "Retry", symbol: "arrow.clockwise", action: store.retryNavigation)
                    .help(attempt.message ?? "Could not open this target")
            case .pending:
                FocusIndicator(isPending: true, isHovered: isHovered)
                    .accessibilityLabel("Opening")
            case .succeeded:
                if showsIdleArrow { FocusIndicator(isPending: false, isHovered: isHovered) }
            }
        } else if fallbackPending || showsIdleArrow {
            FocusIndicator(isPending: fallbackPending, isHovered: isHovered)
        }
    }
}
