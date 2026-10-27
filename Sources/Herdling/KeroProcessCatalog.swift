import Foundation
import OSLog

struct KeroPane: Decodable, Sendable {
    let id: String
    let pid: Int?
}

struct KeroSession: Decodable, Sendable {
    let id: String
    let panes: [KeroPane]
}

struct KeroClientProcess: Equatable, Sendable {
    let paneID: String
    let sourceID: String
    let session: String
}

enum KeroProcessCatalog {
    private static let logger = Logger(subsystem: "dev.herdr.Herdling", category: "kero")

    private struct Process {
        let pid: Int
        let parentPID: Int
        let tty: String
        let command: String
    }

    static func clients(
        from output: String, panes: [KeroPane],
        herdrExecutable: String? = ProcessInfo.processInfo.environment["HERDR_BIN_PATH"]
    ) -> [KeroClientProcess] {
        let processes = output.split(separator: "\n").compactMap(parseProcess)
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return panes.flatMap { pane -> [KeroClientProcess] in
            guard let pid = pane.pid, let root = byPID[pid], root.tty != "??" else { return [] }
            return processes.compactMap { process in
                // Herdr's server and nested panes are not the client displayed by this Kero pane.
                guard process.tty == root.tty,
                      isDescendant(process, of: pid, processes: byPID)
                else { return nil }
                return client(from: process, paneID: pane.id, herdrExecutable: herdrExecutable)
            }
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
        if process.pid == ancestorPID { return true }
        var parentPID = process.parentPID
        var seen: Set<Int> = []
        while parentPID > 1, seen.insert(parentPID).inserted {
            if parentPID == ancestorPID { return true }
            guard let parent = processes[parentPID] else { return false }
            parentPID = parent.parentPID
        }
        return false
    }

    private static func client(from process: Process, paneID: String, herdrExecutable: String?) -> KeroClientProcess? {
        let arguments = HerdrProcessArguments.split(process.command, executable: herdrExecutable)
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

        return KeroClientProcess(
            paneID: paneID,
            sourceID: remote.map { "ssh:\($0)" } ?? "local",
            session: session
        )
    }
}
