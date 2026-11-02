import AppKit
import Darwin
import Foundation

/// A live connection proof, including process birth times to reject recycled PIDs.
struct HerdrAppProcessBinding: Equatable, Sendable {
    let appProcessID: Int32
    let coreProcessID: Int32
    let connectionProcessID: Int32
    let appStarted: UInt64
    let coreStarted: UInt64
    let connectionStarted: UInt64

    static func verify(appProcessID: Int32, coreProcessID: Int32) throws -> Self {
        guard NSRunningApplication(processIdentifier: appProcessID)?.bundleIdentifier == "dev.herdr.app" else {
            throw HerdrAppError.identityUnverified
        }
        let app = try process(appProcessID)
        let core = try process(coreProcessID)
        let children: [Int32]
        do {
            children = try childProcesses(appProcessID).filter { pid in
                guard let invocation = try CoreProcessInvocation.load(pid: Int(pid)) else { return false }
                return Array(invocation.arguments.dropFirst()) == ["connect"]
            }
        } catch { throw HerdrAppError.identityUnverified }
        guard children.count == 1, let connectionPID = children.first else { throw HerdrAppError.identityUnverified }
        let connection = try process(connectionPID)
        guard connection.pbi_ppid == UInt32(appProcessID) else { throw HerdrAppError.identityUnverified }
        let clientSockets = try sockets(connectionPID)
        let serverSockets = try sockets(coreProcessID)
        guard clientSockets.contains(where: { client in
            client.handle != 0 && client.peer != 0 && serverSockets.contains {
                $0.handle == client.peer && $0.peer == client.handle
            }
        }) else { throw HerdrAppError.identityUnverified }
        // Recheck ancestry and birth times after walking descriptors; nothing is cached.
        guard started(try process(appProcessID)) == started(app),
              started(try process(coreProcessID)) == started(core),
              started(try process(connectionPID)) == started(connection) else {
            throw HerdrAppError.identityUnverified
        }
        return Self(appProcessID: appProcessID, coreProcessID: coreProcessID, connectionProcessID: connectionPID,
                    appStarted: started(app), coreStarted: started(core), connectionStarted: started(connection))
    }

    private static func process(_ pid: Int32) throws -> proc_bsdinfo {
        guard pid > 0 else { throw HerdrAppError.identityUnverified }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid() else { throw HerdrAppError.identityUnverified }
        return info
    }

    private static func started(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func childProcesses(_ pid: Int32) throws -> [Int32] {
        let required = proc_listchildpids(pid, nil, 0)
        guard required > 0, required < 1_048_576 else { throw HerdrAppError.identityUnverified }
        var children = [Int32](repeating: 0, count: Int(required) / MemoryLayout<Int32>.stride + 16)
        // Unlike proc_pidinfo, a populated proc_listchildpids call returns a PID count.
        let count = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0, Int(count) < children.count else { throw HerdrAppError.identityUnverified }
        return children.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func sockets(_ pid: Int32) throws -> [(handle: UInt64, peer: UInt64)] {
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard required > 0, required < 1_048_576 else { throw HerdrAppError.identityUnverified }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / stride + 64)
        let bytes = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0, Int(bytes) < descriptors.count * stride, Int(bytes) % stride == 0 else {
            throw HerdrAppError.identityUnverified
        }
        return descriptors.prefix(Int(bytes) / stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_UN, info.psi.soi_family == AF_UNIX,
                  info.psi.soi_type == SOCK_STREAM else { return nil }
            return (info.psi.soi_so, info.psi.soi_proto.pri_un.unsi_conn_so)
        }
    }
}
