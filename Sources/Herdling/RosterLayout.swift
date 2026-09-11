import CoreGraphics
import Foundation

enum BranchSummary: Equatable {
    case single(String)
    case mixed
}

enum RosterLayout {
    static func expandedSourceID(saved: String, available: [String]) -> String? {
        guard !saved.isEmpty else { return nil }
        return available.contains(saved) ? saved : available.first
    }

    static func groupHeaderHeight(branchSummary: BranchSummary?) -> CGFloat {
        branchSummary == nil ? 26 : 38
    }

    static func showsSessionHeader(name: String, sourceSessionCount: Int) -> Bool {
        sourceSessionCount > 1 || name != "default"
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

    let primary: AgentGroup
    let worktrees: [AgentGroup]

    func displayedWorktrees(showEmptyMain: Bool = true) -> [RosterWorktree] {
        (showEmptyMain || !primary.agents.isEmpty ? [RosterWorktree(name: "Main", group: primary)] : []) + worktrees.map {
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
