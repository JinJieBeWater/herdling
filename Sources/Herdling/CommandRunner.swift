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
        standardInput: Data? = nil
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
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = output
        process.standardError = errors

        defer {
            try? output.close()
            try? errors.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        try process.run()
        if let standardInput, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            try inputPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw Error.timedOut
        }
        process.waitUntilExit()
        try output.synchronize()
        try errors.synchronize()

        let data = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.failed(message)
        }
        return data
    }
}
