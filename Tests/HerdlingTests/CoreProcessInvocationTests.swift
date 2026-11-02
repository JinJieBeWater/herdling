import Foundation
import Testing
@testable import Herdling

struct CoreProcessInvocationTests {
    @Test
    func nativeArgumentsKeepSpacesAndEnvironment() throws {
        let invocation = try CoreProcessInvocation.decode(arguments([
            "/Users/me/Core Tools/herdr-core", "connect"
        ], environment: ["HC_SOCKET=/tmp/core A.sock", "HC_SESSION=default"]))
        #expect(invocation.executable == "/Users/me/Core Tools/herdr-core")
        #expect(invocation.arguments == ["/Users/me/Core Tools/herdr-core", "connect"])
        #expect(invocation.environment["HC_SOCKET"] == "/tmp/core A.sock")
    }

    @Test
    func provenNonCoreHelperDoesNotRequireReadableArguments() throws {
        let invocation = try CoreProcessInvocation.load(pid: 1, loadExecutable: { _ in "/usr/bin/login" },
                                                      loadArguments: { _ in
            Issue.record("A proven non-Core helper must not read restricted arguments")
            return nil
        })
        #expect(invocation == nil)
    }

    @Test(arguments: ["hc", "herdr-core"])
    func unreadableCoreStillFailsClosed(executable: String) {
        #expect(throws: CoreClientIdentityError.self) {
            try CoreProcessInvocation.load(pid: 1, loadExecutable: { _ in "/fixture/\(executable)" },
                                           loadArguments: { _ in throw CoreClientIdentityError.unverified })
        }
    }

    @Test
    func malformedOrAmbiguousArgumentsFailClosed() {
        let invalid = [Data(), Data(repeating: 0, count: 16),
                       arguments(["/fixture/hc", "connect"], environment: ["HC_SOCKET=A", "HC_SOCKET=B"])]
        for data in invalid {
            #expect(throws: CoreClientIdentityError.self) { try CoreProcessInvocation.decode(data) }
        }
        #expect(throws: CoreClientIdentityError.self) { try CoreProcessInvocation.load(pid: -1) }
        #expect(throws: CoreClientIdentityError.self) { try CoreProcessInvocation.load(pid: Int.max) }
    }

    private func arguments(_ argv: [String], environment: [String]) -> Data {
        var argc = Int32(argv.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        for value in [argv[0], ""] + argv + environment + [""] {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data
    }
}
