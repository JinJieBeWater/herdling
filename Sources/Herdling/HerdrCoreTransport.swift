import Darwin
import Foundation

protocol HerdrCoreTransport: Sendable {
    var peerProcessID: Int32? { get }
    func write(_ line: Data) throws
    func readLine(timeout: TimeInterval) throws -> Data?
    func close()
}

extension HerdrCoreTransport {
    var peerProcessID: Int32? { nil }
}

enum HerdrCoreError: LocalizedError {
    case invalid(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .unavailable(message): message
        }
    }
}

/// One reader/writer owns the stream; close may interrupt it from another task.
final class HerdrCoreSocket: HerdrCoreTransport, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var buffer = Data()
    private static let maximumLine = 16 * 1024 * 1024

    init(path: String) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HerdrCoreError.invalid("Invalid Core socket path.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes + [0])
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.systemError() }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw Self.systemError() }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw Self.systemError() }
            guard try ready(POLLOUT, deadline: Date().addingTimeInterval(5)) else {
                throw HerdrCoreError.unavailable("Core connection timed out.")
            }
            var code: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: code))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0 else { throw Self.systemError() }
            guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
    }

    deinit { Darwin.close(fd) }

    var peerProcessID: Int32? {
        lock.withLock {
            guard !closed else { return nil }
            var pid: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: pid))
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                  size == MemoryLayout.size(ofValue: pid), pid > 0 else { return nil }
            return pid
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            // Keep the descriptor allocated until deinit so a racing reader cannot use a recycled fd.
            _ = shutdown(fd, SHUT_RDWR)
        }
    }

    func write(_ line: Data) throws {
        guard line.count <= Self.maximumLine else { throw HerdrCoreError.invalid("Core request is too large.") }
        var data = line
        data.append(0x0A)
        let deadline = Date().addingTimeInterval(5)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard try ready(POLLOUT, deadline: deadline) else {
                    throw HerdrCoreError.unavailable("Core write timed out.")
                }
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw Self.systemError() }
            }
        }
    }

    func readLine(timeout: TimeInterval) throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                guard newline <= Self.maximumLine else { throw HerdrCoreError.invalid("Core response is too large.") }
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count <= Self.maximumLine else { throw HerdrCoreError.invalid("Core response is too large.") }
            guard try ready(POLLIN, deadline: deadline) else { return nil }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
            else if count < 0, errno == EINTR || errno == EAGAIN { continue }
            else { throw HerdrCoreError.unavailable("Core socket closed.") }
        }
    }

    private func ready(_ events: Int32, deadline: Date) throws -> Bool {
        while true {
            guard !lock.withLock({ closed }) else { throw CancellationError() }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 5_000)))
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw Self.systemError() }
                return true
            }
            if result < 0, errno != EINTR { throw Self.systemError() }
        }
    }

    private static func systemError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
