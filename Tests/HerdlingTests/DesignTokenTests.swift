import Foundation
import Testing
@testable import Herdling

/// The token system's own enforcement.
///
/// `docs/ui.md` says a value that is not a token does not get written down. That rule decays
/// quietly — one `.system(size: 12)` here, one `minHeight: 26` there — so it is checked here
/// instead of trusted: every file under `Sources/Herdling` is scanned for the literals the token
/// system owns, and the only ones allowed are the ones `Theme` itself states.
///
/// Two exclusions, both deliberate:
/// - `DesignSystem/Theme.swift` *is* the token file; every number in it is a token by definition.
/// - `HerdrBrand.swift` draws the app icon at 512pt with its own brand literal. It is artwork, not
///   interface, and it has no surface on screen to be consistent with.
@Suite
struct DesignTokenTests {
    private static let sourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // HerdlingTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("Sources/Herdling")

    private static let exemptFiles: Set<String> = [
        "DesignSystem/Theme.swift",
        "HerdrBrand.swift",
    ]

    /// Each case is one family of literals. They are separate tests so a failure names the family
    /// rather than "the token check failed".
    @Test(
        arguments: [
            Family(name: "raw colours", pattern: #"(\.foregroundStyle\(\.[a-z]|\.fill\(\.[a-z]|\.tint\(\.[a-z]|\.background\(\.[a-z]|Color\.(white|black|gray)\b|Color\(red:|NSColor\(white:)"#),
            Family(name: "point-sized fonts", pattern: #"\.system\(size: [0-9]"#),
            Family(name: "hard-coded spacing", pattern: #"\.padding\(\.?[a-z]*, ?[0-9]|\.spacing\([0-9]|\.padding\([0-9]"#),
            Family(name: "hard-coded frames", pattern: #"\.frame\((width|height|minWidth|minHeight|maxWidth|maxHeight): [0-9]+(\.[0-9]+)?(?![0-9])|\bminHeight: [0-9]+(?![0-9])"#),
            Family(name: "hard-coded opacity", pattern: #"\.opacity\(0\.[0-9]"#),
            Family(name: "hard-coded animation timing", pattern: #"duration: [0-9]"#),
        ]
    )
    func noLiteralsOutsideTheTokenFile(family: Family) throws {
        let offenders = try Self.literalOffenders(matching: family.pattern)
        #expect(
            offenders.isEmpty,
            """
            \(family.name) written outside the token system:
            \(offenders.joined(separator: "\n"))
            Add it to `Theme`, or use the token that already states it.
            """
        )
    }

    struct Family: CustomTestStringConvertible, Sendable {
        let name: String
        let pattern: String

        var testDescription: String { name }
    }

    private static func sourceFiles() throws -> [URL] {
        let root = sourcesDirectory
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SourceDirectoryMissing(url: root)
        }
        return try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") && !exemptFiles.contains($0) }
            .sorted()
            .map { root.appendingPathComponent($0) }
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func literalOffenders(matching pattern: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        var offenders: [String] = []
        for url in try sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let line = text[..<matchRange.lowerBound].filter { $0 == "\n" }.count + 1
                let name = url.path.replacingOccurrences(of: sourcesDirectory.path + "/", with: "")
                offenders.append("  \(name):\(line)  \(text[matchRange].trimmingCharacters(in: .whitespaces))")
            }
        }
        return offenders
    }

    private struct SourceDirectoryMissing: Error {
        let url: URL
    }
}