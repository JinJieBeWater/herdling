import Foundation
import os

actor GitBranchResolver {
    typealias Query = @Sendable (SourceDescriptor, [String]) -> [String: String]?

    static let shared = GitBranchResolver()
    private static let logger = Logger(subsystem: "dev.herdr.Herdling", category: "branches")

    private struct Key: Hashable {
        let sourceID: String
        let path: String
    }

    private struct Entry {
        let branch: String?
        let checkedAt: Date
    }

    private struct PendingQuery {
        let id = UUID()
        let task: Task<[String: String]?, Never>
    }

    private static let script = #"for path do branch=$(git -C "$path" branch --show-current 2>/dev/null || true); printf '%s\t%s\n' "$path" "$branch"; done"#
    private let cacheDuration: TimeInterval
    private let query: Query
    private var cache: [Key: Entry] = [:]
    private var pending: [Key: PendingQuery] = [:]

    init(
        cacheDuration: TimeInterval = 15,
        query: @escaping Query = { source, paths in GitBranchResolver.query(source: source, paths: paths) }
    ) {
        self.cacheDuration = cacheDuration
        self.query = query
    }

    func branches(source: SourceDescriptor, paths: [String]) async -> [String: String] {
        let paths = Self.unique(paths)
        let now = Date()
        let missing = paths.filter { path in
            guard let entry = cache[Key(sourceID: source.id, path: path)] else { return true }
            return now.timeIntervalSince(entry.checkedAt) >= cacheDuration
        }

        let unqueried = missing.filter { pending[Key(sourceID: source.id, path: $0)] == nil }
        if !unqueried.isEmpty {
            let query = self.query
            let request = PendingQuery(task: Task.detached { query(source, unqueried) })
            for path in unqueried { pending[Key(sourceID: source.id, path: path)] = request }
        }
        let requests = missing.compactMap { path in
            pending[Key(sourceID: source.id, path: path)].map { (path, $0) }
        }
        for (path, request) in requests {
            let resolved = await request.task.value
            let key = Key(sourceID: source.id, path: path)
            guard pending[key]?.id == request.id else { continue }
            pending.removeValue(forKey: key)
            if let resolved {
                cache[key] = Entry(branch: resolved[path], checkedAt: Date())
            }
        }

        return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            cache[Key(sourceID: source.id, path: path)]?.branch.map { (path, $0) }
        })
    }

    static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let separator = line.firstIndex(of: "\t") else { continue }
            let path = String(line[..<separator])
            let branch = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if !branch.isEmpty { result[path] = branch }
        }
        return result
    }

    private static func query(source: SourceDescriptor, paths: [String]) -> [String: String]? {
        do {
            let data: Data
            if let alias = source.sshAlias {
                let command = "$SHELL -lc \(HerdrClient.shellQuote(script)) -- "
                    + paths.map(HerdrClient.shellQuote).joined(separator: " ")
                data = try CommandRunner.run(
                    "/usr/bin/ssh",
                    HerdrClient.sshArguments(alias: alias, command: command),
                    timeout: 7
                )
            } else {
                data = try CommandRunner.run("/bin/sh", ["-c", script, "--"] + paths, timeout: 3)
            }
            return parse(data)
        } catch {
            // Branch labels are cosmetic, so a failed query still means "no branch shown",
            // but the reason has to be recoverable from the log instead of vanishing.
            Self.logger.debug(
                "Branch query failed for \(source.id, privacy: .public) on \(paths.count) path(s): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
