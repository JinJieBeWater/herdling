import AppKit
import Darwin
import Foundation

@MainActor
final class HerdrAppStateObserver {
    private struct State: Equatable {
        let view: Data?
        let socket: UInt64?
    }

    private let home: URL
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    private var watches: [String: (inode: UInt64, source: any DispatchSourceFileSystemObject)] = [:]
    private var state: State?
    private var stopped = false
    private var applicationObservers: [any NSObjectProtocol] = []

    private init(home: URL, continuation: AsyncThrowingStream<Void, Error>.Continuation) {
        self.home = home
        self.continuation = continuation
    }

    static func changes(home: URL? = nil) -> AsyncThrowingStream<Void, Error> {
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do {
            let directory = try home ?? URL(fileURLWithPath: HerdrAppController.home(
                environment: ProcessInfo.processInfo.environment, homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ))
            let observer = HerdrAppStateObserver(home: directory, continuation: continuation)
            continuation.onTermination = { _ in Task { @MainActor in observer.stop() } }
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didActivateApplicationNotification] {
                observer.applicationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak observer] notification in
                    guard (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "dev.herdr.app" else { return }
                    Task { @MainActor in
                        guard let observer, !observer.stopped else { return }
                        observer.continuation.yield(())
                    }
                })
            }
            observer.update()
        } catch {
            continuation.finish(throwing: error)
        }
        return stream
    }

    private func update() {
        guard !stopped else { return }
        do {
            // shortcut: App 0.1.10 persists attention in view.json; use its event API when one becomes available.
            let view = home.appendingPathComponent("view.json").resolvingSymlinksInPath()
            // Watch directories for atomic replacements and the file for in-place writes.
            var paths = Set([existingDirectory(home).path, existingDirectory(view.deletingLastPathComponent()).path])
            if FileManager.default.fileExists(atPath: view.path) { paths.insert(view.path) }
            for path in paths {
                let fd = open(path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { throw HerdrAppError.unavailable }
                var info = stat()
                guard fstat(fd, &info) == 0 else { close(fd); throw HerdrAppError.unavailable }
                let inode = UInt64(info.st_ino)
                if watches[path]?.inode == inode { close(fd); continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke, .attrib], queue: .main
                )
                source.setEventHandler { [weak self] in Task { @MainActor in self?.update() } }
                source.setCancelHandler { close(fd) }
                source.resume()
                watches.removeValue(forKey: path)?.source.cancel()
                watches[path] = (inode, source)
            }
            for path in Set(watches.keys).subtracting(paths) { watches.removeValue(forKey: path)?.source.cancel() }
            let data: Data?
            do { data = try Data(contentsOf: view) }
            catch CocoaError.fileReadNoSuchFile { data = nil }
            var socket = stat()
            let socketPath = home.appendingPathComponent("herdr-app.sock").path
            let socketExists = lstat(socketPath, &socket) == 0
            guard socketExists || errno == ENOENT else { throw HerdrAppError.unavailable }
            let next = State(view: data, socket: socketExists ? UInt64(socket.st_ino) : nil)
            if state != next {
                state = next
                continuation.yield(())
            }
        } catch {
            continuation.finish(throwing: error)
            stop()
        }
    }

    private func existingDirectory(_ url: URL) -> URL {
        var directory = url
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        return directory.resolvingSymlinksInPath()
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        for watch in watches.values { watch.source.cancel() }
        watches.removeAll()
        for observer in applicationObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        applicationObservers.removeAll()
        continuation.onTermination = nil
        continuation.finish()
    }
}
