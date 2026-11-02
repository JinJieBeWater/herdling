import Darwin
import Foundation

struct CoreProcessInvocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]

    static func load(
        pid: Int,
        loadExecutable: @Sendable (Int) throws -> String? = executablePath,
        loadArguments: @Sendable (Int) throws -> CoreProcessInvocation? = kernelArguments
    ) throws -> Self? {
        guard pid > 0, pid <= Int32.max else { throw CoreClientIdentityError.unverified }
        guard let executable = try loadExecutable(pid) else { return nil }
        guard executable.hasPrefix("/") else { throw CoreClientIdentityError.unverified }
        // Root login helpers expose their executable path but deny access to argv/environment.
        guard isCoreExecutable(executable) else { return nil }
        return try loadArguments(pid)
    }

    static func isCoreExecutable(_ path: String) -> Bool {
        ["hc", "herdr-core"].contains(URL(fileURLWithPath: path).lastPathComponent)
    }

    private static func executablePath(pid: Int) throws -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable to Swift.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBytes {
            proc_pidpath(Int32(pid), $0.baseAddress, UInt32($0.count))
        }
        guard result > 0, let end = path.firstIndex(of: 0),
              let executable = String(validating: path[..<end], as: UTF8.self) else {
            if processIsGone(Int32(pid)) { return nil }
            throw CoreClientIdentityError.unverified
        }
        return executable
    }

    private static func kernelArguments(pid: Int) throws -> Self? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else {
            if processIsGone(Int32(pid)) { return nil }
            throw CoreClientIdentityError.unverified
        }
        guard size > 0 else { throw CoreClientIdentityError.unverified }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else {
            if processIsGone(Int32(pid)) { return nil }
            throw CoreClientIdentityError.unverified
        }
        return try decode(data.prefix(size))
    }

    private static func processIsGone(_ pid: Int32) -> Bool {
        // macOS also returns EINVAL for reaped PIDs; signal 0 only checks existence.
        kill(pid, 0) == -1 && errno == ESRCH
    }

    static func decode(_ data: Data) throws -> Self {
        let bytes = [UInt8](data)
        guard bytes.count > MemoryLayout<Int32>.size else { throw CoreClientIdentityError.unverified }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= bytes.count else { throw CoreClientIdentityError.unverified }
        var index = MemoryLayout<Int32>.size
        func string() throws -> String {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0),
                  let value = String(bytes: bytes[index..<end], encoding: .utf8)
            else { throw CoreClientIdentityError.unverified }
            index = end + 1
            return value
        }
        let executable = try string()
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc { arguments.append(try string()) }
        var environment: [String: String] = [:]
        while index < bytes.count, bytes[index] != 0 {
            let entry = try string()
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                throw CoreClientIdentityError.unverified
            }
            let key = String(entry[..<separator])
            guard environment[key] == nil else { throw CoreClientIdentityError.unverified }
            environment[key] = String(entry[entry.index(after: separator)...])
        }
        guard executable.hasPrefix("/"), !arguments.isEmpty else { throw CoreClientIdentityError.unverified }
        return Self(executable: executable, arguments: arguments, environment: environment)
    }
}

enum CoreClientIdentityError: Error {
    case unverified
}
