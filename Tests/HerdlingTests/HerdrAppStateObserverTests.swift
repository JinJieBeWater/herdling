import Foundation
import Testing
@testable import Herdling

@MainActor
struct HerdrAppStateObserverTests {
    @Test
    func watchesCreationAtomicReplacementInPlaceWritesAndRemovalWithoutATimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("config/app")
        let view = home.appendingPathComponent("view.json")
        var count = 0
        let stream = HerdrAppStateObserver.changes(home: home)
        let task = Task { for try await _ in stream { count += 1 } }
        defer { task.cancel() }
        await wait { count == 1 }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: view, options: .atomic)
        await wait { count == 2 }
        try Data("second".utf8).write(to: view, options: .atomic)
        await wait { count == 3 }
        try Data("third".utf8).write(to: view)
        await wait { count == 4 }
        try Data("third".utf8).write(to: view, options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(count == 4)
        try FileManager.default.removeItem(at: home)
        await wait { count == 5 }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("restored".utf8).write(to: view, options: .atomic)
        await wait { count == 6 }
        task.cancel()
        _ = await task.result
        try Data("after cancellation".utf8).write(to: view, options: .atomic)
        try await Task.sleep(for: .milliseconds(50))
        #expect(count == 6)
    }

    @Test
    func followsViewSymlinkTargetAndDoesNotWakeForUnrelatedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("app")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = other.appendingPathComponent("view.json")
        try Data("first".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("view.json"), withDestinationURL: target)
        var count = 0
        let stream = HerdrAppStateObserver.changes(home: home)
        let task = Task { for try await _ in stream { count += 1 } }
        defer { task.cancel() }
        await wait { count == 1 }
        try Data("second".utf8).write(to: target, options: .atomic)
        await wait { count == 2 }
        try Data("unrelated".utf8).write(to: home.appendingPathComponent("other.json"), options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(count == 2)
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
