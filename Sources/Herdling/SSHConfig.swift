import Darwin
import Foundation

enum SSHConfig {
    static func aliases(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    ) -> [String] {
        var aliases: [String] = []
        var visited = Set<URL>()
        parse(
            url: url,
            includeBase: url.deletingLastPathComponent(),
            aliases: &aliases,
            visited: &visited
        )
        return aliases
    }

    private static func parse(
        url: URL,
        includeBase: URL,
        aliases: inout [String],
        visited: inout Set<URL>
    ) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard visited.insert(canonical).inserted,
              let text = try? String(contentsOf: canonical, encoding: .utf8)
        else { return }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let directive = directive(String(rawLine)) else { continue }
            switch directive.keyword {
            case "host":
                for alias in words(directive.value)
                    where isSelectable(alias) && !aliases.contains(alias)
                {
                    aliases.append(alias)
                }
            case "include":
                for pattern in words(directive.value) {
                    for included in expand(pattern: pattern, relativeTo: includeBase) {
                        parse(url: included, includeBase: includeBase, aliases: &aliases, visited: &visited)
                    }
                }
            default:
                continue
            }
        }
    }

    private static func directive(_ rawLine: String) -> (keyword: String, value: String)? {
        let line = withoutComment(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty,
              let separator = line.firstIndex(where: { $0 == "=" || $0.isWhitespace })
        else { return nil }

        let keyword = line[..<separator].lowercased()
        var value = line[separator...].drop(while: { $0 == "=" || $0.isWhitespace })
        if value.first == "=" {
            value = value.dropFirst().drop(while: \Character.isWhitespace)
        }
        return (keyword, String(value))
    }

    private static func withoutComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                result.append(character)
                escaped = true
            } else if let activeQuote = quote {
                result.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                result.append(character)
                quote = character
            } else if character == "#" {
                break
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func words(_ value: String) -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false

        func finish() {
            if !token.isEmpty {
                result.append(token)
                token = ""
            }
        }

        for character in value {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                finish()
            } else {
                token.append(character)
            }
        }
        if escaped { token.append("\\") }
        finish()
        return result
    }

    private static func isSelectable(_ alias: String) -> Bool {
        !alias.isEmpty
            && !alias.hasPrefix("-")
            && !alias.contains("*")
            && !alias.contains("?")
            && !alias.contains("!")
    }

    private static func expand(pattern: String, relativeTo base: URL) -> [URL] {
        let expanded = (pattern as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
        var matches = glob_t()
        let status = absolute.withCString { glob($0, 0, nil, &matches) }
        defer { globfree(&matches) }
        guard status == 0, let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            paths[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}
