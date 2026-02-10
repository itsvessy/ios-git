import Core
import CryptoKit
import Foundation
import SwiftGitX

public struct NullCredentialProvider: SSHCredentialProvider {
    public init() {}

    public func credential(for host: String, username: String?) async throws -> SSHCredentialMaterial {
        throw RepoError.keyNotFound
    }
}

public actor FileSystemGitClient: GitClient {
    private let fileManager: FileManager
    private let trustEvaluator: HostTrustEvaluator
    private let credentialProvider: SSHCredentialProvider

    public init(
        fileManager: FileManager = .default,
        trustEvaluator: HostTrustEvaluator,
        credentialProvider: SSHCredentialProvider = NullCredentialProvider()
    ) {
        self.fileManager = fileManager
        self.trustEvaluator = trustEvaluator
        self.credentialProvider = credentialProvider
    }

    public func probeRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        let parsed = try SSHRemoteURL(parse: remoteURL)
        return RemoteProbeResult(host: parsed.host, port: parsed.port, normalizedURL: parsed.normalized)
    }

    public func clone(_ request: CloneRequest) async throws -> RepoRecord {
        let parsed = try SSHRemoteURL(parse: request.remoteURL)
        let fingerprint = syntheticHostFingerprint(host: parsed.host, port: parsed.port)
        _ = try await trustEvaluator.evaluate(
            host: parsed.host,
            port: parsed.port,
            presentedFingerprint: fingerprint,
            algorithm: "ed25519"
        )

        let credential = try await credentialProvider.credential(for: parsed.host, username: parsed.user)

        return try await withSecurityScopedAccess(
            directoryURL: request.targetDirectory,
            bookmarkData: request.targetDirectoryBookmark
        ) { accessibleRoot in
            let repoID = RepoID()
            let preferredFolderName = sanitizedRepositoryFolderName(request.displayName)
            let destination = uniqueDestination(in: accessibleRoot, preferredName: preferredFolderName)

            try fileManager.createDirectory(at: accessibleRoot, withIntermediateDirectories: true)

            do {
                try await withSSHAuthentication(credential: credential) { authentication in
                    guard let remote = URL(string: parsed.normalized) else {
                        throw RepoError.invalidRemoteURL
                    }

                    _ = try await Repository.clone(
                        from: remote,
                        to: destination,
                        authentication: authentication
                    )
                }
            } catch let error as SwiftGitXError {
                throw map(error: error)
            }

            do {
                let repository = try Repository.open(at: destination)
                try checkoutTrackedBranchIfAvailable(repository: repository, trackedBranch: request.trackedBranch)
            } catch let error as SwiftGitXError {
                throw map(error: error)
            }

            return RepoRecord(
                id: repoID,
                displayName: request.displayName,
                remoteURL: parsed.normalized,
                localPath: destination.path(),
                securityScopedBookmark: makeSecurityScopedBookmark(for: destination),
                trackedBranch: request.trackedBranch,
                autoSyncEnabled: request.autoSyncEnabled,
                lastSyncAt: nil,
                lastSyncState: .idle,
                lastErrorMessage: nil
            )
        }
    }

    public func sync(_ repo: RepoRecord, trigger: SyncTrigger) async throws -> SyncResult {
        return try await withSecurityScopedAccess(
            directoryURL: URL(fileURLWithPath: repo.localPath, isDirectory: true),
            bookmarkData: repo.securityScopedBookmark
        ) { repositoryURL in
            guard fileManager.fileExists(atPath: repositoryURL.path) else {
                return SyncResult(state: .failed, message: "Repository directory missing.")
            }

            if trigger == .background {
                let deferMarker = repositoryURL.appendingPathComponent(".gitphone-defer-background")
                if fileManager.fileExists(atPath: deferMarker.path) {
                    return SyncResult(state: .networkDeferred, message: "Background sync deferred by policy.")
                }
            }

            let parsed = try SSHRemoteURL(parse: repo.remoteURL)
            let fingerprint = syntheticHostFingerprint(host: parsed.host, port: parsed.port)
            _ = try await trustEvaluator.evaluate(
                host: parsed.host,
                port: parsed.port,
                presentedFingerprint: fingerprint,
                algorithm: "ed25519"
            )

            let credential = try await credentialProvider.credential(for: parsed.host, username: parsed.user)

            do {
                return try await withSSHAuthentication(credential: credential) { authentication in
                    let repository = try Repository.open(at: repositoryURL)

                    if try hasWorkingTreeChanges(repository) {
                        throw RepoError.dirtyWorkingTree
                    }

                    try await repository.fetch(
                        remote: repository.remote["origin"],
                        authentication: authentication
                    )
                    return try fastForwardPull(repository: repository, trackedBranch: repo.trackedBranch)
                }
            } catch let error as SwiftGitXError {
                throw map(error: error)
            }
        }
    }

    private func checkoutTrackedBranchIfAvailable(repository: Repository, trackedBranch: String) throws {
        if let local = repository.branch[trackedBranch, type: .local] {
            try repository.switch(to: local)
            return
        }

        if let remote = repository.branch["origin/\(trackedBranch)", type: .remote] {
            try repository.switch(to: remote)
        }
    }

    private func fastForwardPull(repository: Repository, trackedBranch: String) throws -> SyncResult {
        guard let remoteBranch = repository.branch["origin/\(trackedBranch)", type: .remote] else {
            return SyncResult(state: .failed, message: "Remote branch origin/\(trackedBranch) not found.")
        }

        if let localBranch = repository.branch[trackedBranch, type: .local] {
            try repository.switch(to: localBranch)
        } else {
            try repository.switch(to: remoteBranch)
        }

        guard let localBranch = repository.branch[trackedBranch, type: .local] else {
            return SyncResult(state: .failed, message: "Local branch \(trackedBranch) not available.")
        }

        guard let localCommit = localBranch.target as? Commit,
              let remoteCommit = remoteBranch.target as? Commit else {
            return SyncResult(state: .failed, message: "Unable to resolve branch tips for pull.")
        }

        if localCommit.id == remoteCommit.id {
            return SyncResult(state: .success, message: "Already up to date.")
        }

        if try isAncestor(ancestorHex: localCommit.id.hex, of: remoteCommit) {
            try repository.reset(to: remoteCommit, mode: .hard)
            return SyncResult(state: .success)
        }

        if try isAncestor(ancestorHex: remoteCommit.id.hex, of: localCommit) {
            return SyncResult(state: .success, message: "Local branch is ahead of remote.")
        }

        throw RepoError.divergedBranch
    }

    private func hasWorkingTreeChanges(_ repository: Repository) throws -> Bool {
        let statuses = try repository.status()
        for entry in statuses {
            let isOnlyIgnoredOrCurrent = entry.status.allSatisfy { status in
                switch status {
                case .current, .ignored:
                    return true
                default:
                    return false
                }
            }
            if !isOnlyIgnoredOrCurrent {
                return true
            }
        }
        return false
    }

    private func isAncestor(ancestorHex: String, of descendant: Commit) throws -> Bool {
        var queue: [Commit] = [descendant]
        var seen: Set<String> = []

        while let current = queue.popLast() {
            let hex = current.id.hex
            if hex == ancestorHex {
                return true
            }
            if !seen.insert(hex).inserted {
                continue
            }
            queue.append(contentsOf: try current.parents)
        }

        return false
    }

    private func withSSHAuthentication<T: Sendable>(
        credential: SSHCredentialMaterial,
        operation: (SSHAuthentication) async throws -> T
    ) async throws -> T {
        let keyURL = try writeTemporaryPrivateKey(credential.privateKey)
        defer {
            try? fileManager.removeItem(at: keyURL)
        }

        let authentication = SSHAuthentication(
            username: credential.username,
            privateKeyPath: keyURL.path,
            passphrase: credential.passphrase,
            acceptUntrustedHost: true
        )
        return try await operation(authentication)
    }

    private func writeTemporaryPrivateKey(_ privateKey: Data) throws -> URL {
        let keyString = try renderPrivateKey(privateKey)
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("gitphone-ssh", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data(keyString.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL
    }

    private func renderPrivateKey(_ raw: Data) throws -> String {
        if let text = String(data: raw, encoding: .utf8),
           text.contains("PRIVATE KEY") {
            return text.hasSuffix("\n") ? text : text + "\n"
        }

        if raw.count == 32 {
            return try makeOpenSSHEd25519PrivateKey(fromSeed: raw)
        }

        if raw.first == 0x30 {
            let body = raw.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            return "-----BEGIN RSA PRIVATE KEY-----\n\(body)-----END RSA PRIVATE KEY-----\n"
        }

        throw RepoError.keychainFailure("unsupported private key format for SSH command")
    }

    private func makeOpenSSHEd25519PrivateKey(fromSeed seed: Data) throws -> String {
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            throw RepoError.keychainFailure("invalid Ed25519 key material")
        }

        let publicKey = privateKey.publicKey.rawRepresentation
        let keyType = Data("ssh-ed25519".utf8)

        var publicBlob = Data()
        publicBlob.append(encodeSSHString(keyType))
        publicBlob.append(encodeSSHString(publicKey))

        var privateBlob = Data()
        let check = UInt32.random(in: UInt32.min...UInt32.max)
        privateBlob.append(encodeUInt32(check))
        privateBlob.append(encodeUInt32(check))
        privateBlob.append(encodeSSHString(keyType))
        privateBlob.append(encodeSSHString(publicKey))

        var privateAndPublic = Data()
        privateAndPublic.append(seed)
        privateAndPublic.append(publicKey)
        privateBlob.append(encodeSSHString(privateAndPublic))
        privateBlob.append(encodeSSHString(Data("gitphone".utf8)))

        var pad: UInt8 = 1
        while privateBlob.count % 8 != 0 {
            privateBlob.append(pad)
            pad &+= 1
        }

        var envelope = Data("openssh-key-v1\u{0}".utf8)
        envelope.append(encodeSSHString(Data("none".utf8)))
        envelope.append(encodeSSHString(Data("none".utf8)))
        envelope.append(encodeSSHString(Data()))
        envelope.append(encodeUInt32(1))
        envelope.append(encodeSSHString(publicBlob))
        envelope.append(encodeSSHString(privateBlob))

        let body = envelope.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let normalizedBody = body.hasSuffix("\n") ? body : body + "\n"
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(normalizedBody)-----END OPENSSH PRIVATE KEY-----\n"
    }

    private func encodeUInt32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private func encodeSSHString(_ payload: Data) -> Data {
        var output = Data()
        output.append(encodeUInt32(UInt32(payload.count)))
        output.append(payload)
        return output
    }

    private func withSecurityScopedAccess<T: Sendable>(
        directoryURL: URL,
        bookmarkData: Data?,
        operation: (URL) async throws -> T
    ) async throws -> T {
        let resolvedURL: URL
        var hasScopedAccess = false

        if let bookmarkData {
            var isStale = false
            do {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw RepoError.ioFailure("Could not resolve folder permission bookmark.")
            }
            _ = isStale
            hasScopedAccess = resolvedURL.startAccessingSecurityScopedResource()
        } else {
            resolvedURL = directoryURL
        }

        defer {
            if hasScopedAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation(resolvedURL)
    }

    private func makeSecurityScopedBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return nil
        }
    }

    private func uniqueDestination(in root: URL, preferredName: String) -> URL {
        var candidate = root.appendingPathComponent(preferredName, isDirectory: true)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        var suffix = 2
        while true {
            candidate = root.appendingPathComponent("\(preferredName)-\(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func sanitizedRepositoryFolderName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))

        return cleaned.isEmpty ? "Repository" : cleaned
    }

    private func syntheticHostFingerprint(host: String, port: Int) -> String {
        let digest = SHA256.hash(data: Data("\(host):\(port)".utf8))
        return "SHA256:\(Data(digest).base64EncodedString())"
    }

    private func map(error: SwiftGitXError) -> RepoError {
        let loweredMessage = error.message.lowercased()
        switch error.code {
        case .auth:
            return .syncBlocked("SSH authentication failed. Verify repo access and ensure this app's public key is added on your Git host.")
        case .certificate:
            return .hostTrustRejected
        case .nonFastForward, .mergeConflict, .conflict:
            return .divergedBranch
        default:
            if loweredMessage.contains("could not read refs from remote repository") ||
                loweredMessage.contains("permission denied") {
                return .syncBlocked("SSH authentication failed. Verify repo access and ensure this app's public key is added on your Git host.")
            }
            if error.category == .net {
                return .syncBlocked(error.message)
            }
            return .ioFailure(error.message)
        }
    }
}
