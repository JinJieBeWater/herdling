import Darwin
import Foundation

final class SingleInstanceLock {
    static let activationNotification = Notification.Name("dev.herdr.Herdling.activate")

    private let stateLock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(
        identifier: String,
        directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) -> SingleInstanceLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeIdentifier = identifier.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let path = directory.appendingPathComponent(String(safeIdentifier) + ".lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return SingleInstanceLock(descriptor: descriptor)
    }

    func release() {
        let descriptor = stateLock.withLock { () -> Int32? in
            defer { self.descriptor = nil }
            return self.descriptor
        }
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit {
        release()
    }
}
