import Darwin
import Foundation

enum CommandRunner {
    enum Error: LocalizedError {
        case timedOut
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "Command did not respond before the timeout."
            case let .failed(message):
                message.isEmpty ? "Command failed." : message
            }
        }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        standardInput: Data? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let inputPipe = standardInput == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        let directory = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let outputURL = directory.appendingPathComponent("herdling-\(token).out")
        let errorURL = directory.appendingPathComponent("herdling-\(token).err")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        process.standardOutput = output
        process.standardError = errors

        let input = inputPipe?.fileHandleForWriting
        defer { try? input?.close() }
        if let input, fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            throw Error.failed("Could not configure command input.")
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer {
            if process.isRunning { stop(process) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        if let standardInput, let input {
            try writeInput(standardInput, to: input, deadline: deadline, isCancelled: isCancelled)
            try input.close()
        }
        while process.isRunning, Date() < deadline {
            if isCancelled() {
                stop(process)
                throw CancellationError()
            }
            _ = exited.wait(timeout: .now() + min(0.05, max(0, deadline.timeIntervalSinceNow)))
        }
        if process.isRunning {
            stop(process)
            throw Error.timedOut
        }
        process.waitUntilExit()

        let data = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.failed(message)
        }
        return data
    }

    private static func writeInput(
        _ data: Data,
        to input: FileHandle,
        deadline: Date,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let fd = input.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if isCancelled() { throw CancellationError() }
                guard Date() < deadline else { throw Error.timedOut }
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if written == -1, code == EINTR { continue }
                guard written == -1, code == EAGAIN else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(written == 0 ? EIO : code))
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(min(50, max(0, deadline.timeIntervalSinceNow * 1000)))
                if poll(&descriptor, 1, milliseconds) == -1, errno != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
    }

    private static func stop(_ process: Process) {
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
