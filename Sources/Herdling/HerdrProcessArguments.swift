import Foundation

enum HerdrProcessArguments {
    static func split(_ command: String, executable: String?) -> [String] {
        // `ps` flattens argv; an exact known path restores the executable boundary without guessing.
        if let executable, !executable.isEmpty,
           command == executable || command.hasPrefix(executable + " ") {
            return [executable] + command.dropFirst(executable.count).split(whereSeparator: \Character.isWhitespace).map(String.init)
        }
        // shortcut: unconfigured paths containing whitespace stay unrecognized; use kernel argv if adoption must cover them.
        return command.split(whereSeparator: \Character.isWhitespace).map(String.init)
    }
}
