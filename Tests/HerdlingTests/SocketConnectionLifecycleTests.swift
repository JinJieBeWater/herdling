import Darwin
import Foundation
import Testing
@testable import Herdling

struct SocketConnectionLifecycleTests {
    @Test
    func replacingConnectionStopsPreviousTransportAndKeepsCurrentUsable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdling-lifecycle-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = HerdrSocketEndpoint(session: "fixture", path: "/unused")
        let previousPIDFile = directory.appendingPathComponent("previous.pid")
        let currentPIDFile = directory.appendingPathComponent("current.pid")
        let previous = transport(endpoint: endpoint, pidFile: previousPIDFile)
        let current = transport(endpoint: endpoint, pidFile: currentPIDFile)
        defer { previous.stop(); current.stop() }
        let roster = HerdrSocketRoster()

        try previous.start()
        try current.start()
        let previousPID = try transportPID(at: previousPIDFile)
        let currentPID = try transportPID(at: currentPIDFile)
        try #require(kill(previousPID, 0) == 0)
        try #require(kill(currentPID, 0) == 0)
        await roster.addConnection(previous, for: endpoint)

        await roster.addConnection(current, for: endpoint)
        await roster.addConnection(current, for: endpoint)

        // stop() must reap the old child before replacement returns, not merely drop its owner.
        let previousStatus = kill(previousPID, 0)
        let previousError = errno
        #expect(previousStatus == -1 && previousError == ESRCH)
        #expect(kill(currentPID, 0) == 0)
        #expect(try current.refresh())
        #expect(await roster.existingConnections([endpoint]).first?.1.id == current.id)
        await roster.stop()
        let currentStatus = kill(currentPID, 0)
        let currentError = errno
        #expect(currentStatus == -1 && currentError == ESRCH)
    }

    private func transport(endpoint: HerdrSocketEndpoint, pidFile: URL) -> HerdrSocketConnection {
        HerdrSocketConnection(
            endpoint: endpoint,
            eventExecutable: "/bin/sh",
            eventArguments: [
                "-c",
                """
                IFS= read -r request || exit
                printf '%s\\n' "$$" > \(HerdrClient.shellQuote(pidFile.path))
                printf '%s\\n' '{"id":"subscription","result":{"type":"subscription_started"}}'
                while IFS= read -r request; do :; done
                """,
            ],
            loadSnapshot: { [] },
            onSnapshot: { _, _, _, _ in },
            onEnd: { _, _ in }
        )
    }

    private func transportPID(at file: URL) throws -> pid_t {
        // The shell writes its own PID before acknowledging subscription; start() is the barrier.
        let value = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(value))
    }
}
