import Testing
@testable import Herdling

struct ProcessCatalogTests {
    @Test(arguments: ["herdr", "/opt/homebrew/bin/herdr", "/Users/me/Library/Application Support/herdr",
                      "/Users/me/herdr --session decoy/bin/herdr"])
    func catalogsRecognizeTheExactHerdrExecutable(executable: String) {
        let output = """
        100 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
        110 100 ttys000 /bin/zsh
        111 110 ttys000 \(executable) --remote kvm --session work
        """
        #expect(GhosttyProcessCatalog.clients(from: output, ghosttyPID: 100, herdrExecutable: executable) == [
            .init(tty: "ttys000", sourceID: "ssh:kvm", session: "work"),
        ])
        #expect(KeroProcessCatalog.clients(from: output, panes: [.init(id: "pane", pid: 110)], herdrExecutable: executable) == [
            .init(paneID: "pane", sourceID: "ssh:kvm", session: "work"),
        ])
    }

    @Test
    func spacedPathsKeepClientAndProcessGuards() {
        let executable = "/Users/me/Library/Application Support/herdr"
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
