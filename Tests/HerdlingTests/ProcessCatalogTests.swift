import Testing
@testable import Herdling

struct ProcessCatalogTests {
    @Test
    func ttyIdentityAcceptsOnlyExactASCIIFormats() {
        #expect(GhosttyProcessCatalog.normalizedTTY("/dev/ttys007") == "ttys007")
        #expect(GhosttyProcessCatalog.normalizedTTY("ttys007") == "ttys007")
        for invalid in ["ttys", "ttys００７", "ttys007 ", " /dev/ttys007", "/dev/../dev/ttys007", "/tmp/ttys007"] {
            #expect(GhosttyProcessCatalog.normalizedTTY(invalid) == nil)
        }
        #expect(GhosttyProcessCatalog.clients(
            from: "101 100 /dev/ttys007 /opt/homebrew/bin/herdr", ghosttyPID: 100
        ) == [.init(tty: "ttys007", sourceID: "local", session: "default")])
    }

    @Test
    func spacedPathsKeepClientAndProcessGuards() {
        let executable = "/Users/me/Library/Application Support/herdr --session decoy/bin/herdr"
        let output = """
        100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
        110 100 ttys000 /bin/zsh
        111 110 ttys000 \(executable)
        112 110 ttys000 \(executable) --remote other --session other --remote-keybindings local
        113 110 ttys000 \(executable)-helper --session work
        114 110 ttys000 \(executable) server
        115 110 ttys000 \(executable) --unknown flag
        116 110 ttys000 \(executable) --session
        117 110 ttys000 \(executable) --remote
        118 110 ttys000 /bin/sh -c \(executable)
        119 110 ?? \(executable) --session detached
        120 1 ttys000 \(executable) --session unrelated
        """
        #expect(GhosttyProcessCatalog.clients(from: output, ghosttyPID: 100, herdrExecutable: executable) == [
            .init(tty: "ttys000", sourceID: "local", session: "default"),
            .init(tty: "ttys000", sourceID: "ssh:other", session: "other"),
        ])
        #expect(KeroProcessCatalog.clients(from: output, panes: [.init(id: "pane", pid: 110)], herdrExecutable: executable) == [
            .init(paneID: "pane", sourceID: "local", session: "default"),
            .init(paneID: "pane", sourceID: "ssh:other", session: "other"),
        ])
    }
}
