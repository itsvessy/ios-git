import Foundation

public struct SSHRemoteURL: Hashable, Sendable {
    public let original: String
    public let user: String
    public let host: String
    public let port: Int
    public let path: String

    public static let defaultPort = 22

    public init(parse remoteURL: String) throws {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepoError.invalidRemoteURL
        }

        if trimmed.hasPrefix("ssh://") {
            guard let components = URLComponents(string: trimmed),
                  let host = components.host,
                  let user = components.user,
                  var path = components.path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/").nonEmpty else {
                throw RepoError.invalidRemoteURL
            }

            if path.hasPrefix("/") {
                path.removeFirst()
            }

            self.original = trimmed
            self.user = user
            self.host = host
            self.port = components.port ?? Self.defaultPort
            self.path = path
            return
        }

        guard let atIndex = trimmed.firstIndex(of: "@") else {
            throw RepoError.unsupportedRemoteScheme
        }

        let user = String(trimmed[..<atIndex])
        let hostAndPath = trimmed[trimmed.index(after: atIndex)...]
        guard let colonIndex = hostAndPath.firstIndex(of: ":") else {
            throw RepoError.invalidRemoteURL
        }

        let host = String(hostAndPath[..<colonIndex])
        let pathStart = hostAndPath.index(after: colonIndex)
        let path = String(hostAndPath[pathStart...])

        guard !user.isEmpty, !host.isEmpty, !path.isEmpty else {
            throw RepoError.invalidRemoteURL
        }

        self.original = trimmed
        self.user = user
        self.host = host
        self.port = Self.defaultPort
        self.path = path
    }

    public var normalized: String {
        "ssh://\(user)@\(host):\(port)/\(path)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
