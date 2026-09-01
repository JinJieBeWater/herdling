import Foundation

struct SourceDescriptor: Identifiable, Hashable, Sendable {
    static let local = SourceDescriptor(
        id: "local",
        name: localDisplayName(fullName: NSFullUserName(), username: NSUserName()),
        sshAlias: nil
    )

    let id: String
    let name: String
    let sshAlias: String?

    static func remote(_ alias: String) -> SourceDescriptor {
        SourceDescriptor(id: "ssh:\(alias)", name: alias, sshAlias: alias)
    }

    static func localDisplayName(fullName: String, username: String) -> String {
        let fullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty { return fullName }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? "Local" : username
    }
}
