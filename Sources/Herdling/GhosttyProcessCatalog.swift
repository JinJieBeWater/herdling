import Foundation
import OSLog

struct GhosttyClientProcess: Equatable, Sendable {
    let tty: String
    let sourceID: String
    let session: String
}

enum GhosttyProcessCatalog {
    private static let logger = Logger(subsystem: "dev.herdr.Herdling", category: "ghostty")

    private struct Process {
        let pid: Int
        let parentPID: Int
        let tty: String
        let command: String
    }

    static func load(ghosttyPID: Int, timeout: TimeInterval = 1) throws -> [GhosttyClientProcess] {
        let data = try CommandRunner.run(
            "/bin/ps",
            ["-axo", "pid=,ppid=,tty=,command="],
            timeout: timeout
        )
        return clients(from: String(decoding: data, as: UTF8.self), ghosttyPID: ghosttyPID)
    }

    static func clients(from output: String, ghosttyPID: Int) -> [GhosttyClientProcess] {
        let processes = output.split(separator: "\n").compactMap(parseProcess)
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return processes.compactMap { process in
            guard process.tty != "??",
                  isDescendant(process, of: ghosttyPID, processes: byPID)
            else { return nil }
            return client(from: process)
        }
    }

    private static func parseProcess(_ line: Substring) -> Process? {
        let fields = line.split(maxSplits: 3, whereSeparator: \Character.isWhitespace)
        guard fields.count == 4,
              let pid = Int(fields[0]),
              let parentPID = Int(fields[1])
        else { return nil }
        return Process(
            pid: pid,
            parentPID: parentPID,
            tty: String(fields[2]),
            command: String(fields[3])
        )
    }

    private static func isDescendant(
        _ process: Process,
        of ancestorPID: Int,
        processes: [Int: Process]
    ) -> Bool {
        var parentPID = process.parentPID
        var seen: Set<Int> = []
        while parentPID > 1, seen.insert(parentPID).inserted {
            if parentPID == ancestorPID { return true }
            guard let parent = processes[parentPID] else { return false }
            parentPID = parent.parentPID
        }
        return false
    }

    private static func client(from process: Process) -> GhosttyClientProcess? {
        let arguments = process.command.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard let executable = arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent == "herdr"
        else { return nil }

        var remote: String?
        var session = "default"
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--remote":
                guard index + 1 < arguments.count else { return nil }
                remote = arguments[index + 1]
                index += 2
            case "--session", "--remote-keybindings":
                guard index + 1 < arguments.count else { return nil }
                if arguments[index] == "--session" { session = arguments[index + 1] }
                index += 2
            default:
                // Failing closed keeps non-client invocations (`herdr server`, `machine add`, ...) out
                // of the roster, but a flag added by a Herdr update would stop window reuse silently.
                logger.debug("Skipped herdr process with unrecognized argument \(arguments[index], privacy: .public)")
                return nil
            }
        }

        return GhosttyClientProcess(
            tty: process.tty,
            sourceID: remote.map { "ssh:\($0)" } ?? "local",
            session: session
        )
    }
}
