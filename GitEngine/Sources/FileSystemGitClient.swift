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
    private let operationLock: RepoOperationLock

    public init(
        fileManager: FileManager = .default,
        trustEvaluator: HostTrustEvaluator,
        credentialProvider: SSHCredentialProvider = NullCredentialProvider(),
        operationLock: RepoOperationLock = RepoOperationLock()
    ) {
        self.fileManager = fileManager
        self.trustEvaluator = trustEvaluator
        self.credentialProvider = credentialProvider
        self.operationLock = operationLock
    }

    public func probeRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        let parsed = try SSHRemoteURL(parse: remoteURL)
        return makeProbeResult(from: parsed)
    }

    public func prepareRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        let parsed = try SSHRemoteURL(parse: remoteURL)
        try await evaluateHostTrust(parsed)
        return makeProbeResult(from: parsed)
    }

    public func clone(_ request: CloneRequest) async throws -> RepoRecord {
        let parsed = try SSHRemoteURL(parse: request.remoteURL)
        try await evaluateHostTrust(parsed)

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
        try await withRepoLock(repo.id) {
            try await self.syncUnlocked(repo, trigger: trigger)
        }
    }

    public func listLocalChanges(_ repo: RepoRecord) async throws -> [RepoLocalChange] {
        do {
            return try await withRepositoryAccess(repo) { repository, _ in
                let statuses = try repository.status()
                return self.makeLocalChanges(from: statuses)
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    public func stage(_ repo: RepoRecord, paths: [String]) async throws {
        try await withRepoLock(repo.id) {
            try await self.stageUnlocked(repo, paths: paths)
        }
    }

    public func stageAll(_ repo: RepoRecord) async throws {
        try await withRepoLock(repo.id) {
            try await self.stageAllUnlocked(repo)
        }
    }

    public func loadCommitIdentity(_ repo: RepoRecord) async throws -> RepoCommitIdentity? {
        do {
            return try await withRepositoryAccess(repo) { repository, _ in
                try self.loadCommitIdentity(from: repository)
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    public func saveCommitIdentity(_ identity: RepoCommitIdentity, for repo: RepoRecord) async throws {
        try await withRepoLock(repo.id) {
            try await self.saveCommitIdentityUnlocked(identity, for: repo)
        }
    }

    public func commit(_ repo: RepoRecord, message: String) async throws -> RepoCommitResult {
        try await withRepoLock(repo.id) {
            try await self.commitUnlocked(repo, message: message)
        }
    }

    public func push(_ repo: RepoRecord) async throws -> RepoPushResult {
        try await withRepoLock(repo.id) {
            try await self.pushUnlocked(repo)
        }
    }

    public func discardLocalChanges(_ repo: RepoRecord) async throws {
        try await withRepoLock(repo.id) {
            try await self.discardLocalChangesUnlocked(repo)
        }
    }

    public func resetToRemote(_ repo: RepoRecord) async throws -> SyncResult {
        try await withRepoLock(repo.id) {
            try await self.resetToRemoteUnlocked(repo)
        }
    }

    private func withRepoLock<T>(
        _ repoID: RepoID,
        operation: () async throws -> T
    ) async throws -> T {
        await operationLock.lock(repoID: repoID)
        do {
            let result = try await operation()
            await operationLock.unlock(repoID: repoID)
            return result
        } catch {
            await operationLock.unlock(repoID: repoID)
            throw error
        }
    }

    private func syncUnlocked(_ repo: RepoRecord, trigger: SyncTrigger) async throws -> SyncResult {
        return try await withSecurityScopedAccess(
            directoryURL: URL(fileURLWithPath: repo.localPath, isDirectory: true),
            bookmarkData: repo.securityScopedBookmark
        ) { repositoryURL in
            guard self.fileManager.fileExists(atPath: repositoryURL.path) else {
                return SyncResult(state: .failed, message: "Repository directory missing.")
            }

            if trigger == .background {
                let deferMarker = repositoryURL.appendingPathComponent(".gitphone-defer-background")
                if self.fileManager.fileExists(atPath: deferMarker.path) {
                    return SyncResult(state: .networkDeferred, message: "Background sync deferred by policy.")
                }
            }

            let parsed = try SSHRemoteURL(parse: repo.remoteURL)
            try await self.evaluateHostTrust(parsed)

            let credential = try await self.credentialProvider.credential(for: parsed.host, username: parsed.user)

            do {
                return try await self.withSSHAuthentication(credential: credential) { authentication in
                    let repository = try Repository.open(at: repositoryURL)

                    if try self.hasWorkingTreeChanges(repository) {
                        throw RepoError.dirtyWorkingTree
                    }

                    try await repository.fetch(
                        remote: repository.remote["origin"],
                        authentication: authentication
                    )
                    return try self.fastForwardPull(repository: repository, trackedBranch: repo.trackedBranch)
                }
            } catch let error as SwiftGitXError {
                throw self.map(error: error)
            }
        }
    }

    private func stageUnlocked(_ repo: RepoRecord, paths: [String]) async throws {
        let trimmedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedPaths.isEmpty else {
            throw RepoError.nothingToStage
        }

        do {
            try await withRepositoryAccess(repo) { repository, _ in
                try self.stagePaths(in: repository, paths: trimmedPaths)
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func stageAllUnlocked(_ repo: RepoRecord) async throws {
        do {
            try await withRepositoryAccess(repo) { repository, _ in
                let statuses = try repository.status()
                let paths = self.makeLocalChanges(from: statuses).map(\.path)
                guard !paths.isEmpty else {
                    throw RepoError.nothingToStage
                }
                try self.stagePaths(in: repository, paths: paths)
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func saveCommitIdentityUnlocked(_ identity: RepoCommitIdentity, for repo: RepoRecord) async throws {
        let name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = identity.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else {
            throw RepoError.commitIdentityMissing
        }

        do {
            try await withRepositoryAccess(repo) { repository, _ in
                try repository.config.set("user.name", to: name)
                try repository.config.set("user.email", to: email)
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func commitUnlocked(_ repo: RepoRecord, message: String) async throws -> RepoCommitResult {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw RepoError.invalidCommitMessage
        }

        do {
            return try await withRepositoryAccess(repo) { repository, _ in
                guard try self.loadCommitIdentity(from: repository) != nil else {
                    throw RepoError.commitIdentityMissing
                }

                let statuses = try repository.status()
                guard self.hasStagedChanges(statuses) else {
                    throw RepoError.nothingToCommit
                }

                let committed = try repository.commit(message: trimmedMessage)
                return RepoCommitResult(
                    commitID: committed.id.hex,
                    message: trimmedMessage,
                    committedAt: Date()
                )
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func pushUnlocked(_ repo: RepoRecord) async throws -> RepoPushResult {
        let parsed = try SSHRemoteURL(parse: repo.remoteURL)
        try await evaluateHostTrust(parsed)
        let credential = try await credentialProvider.credential(for: parsed.host, username: parsed.user)

        do {
            return try await withRepositoryAccess(repo) { repository, _ in
                try await self.withSSHAuthentication(credential: credential) { authentication in
                    try await repository.push(
                        remote: repository.remote["origin"],
                        authentication: authentication
                    )
                    let currentBranch = (try? repository.branch.current.name) ?? repo.trackedBranch
                    return RepoPushResult(
                        remoteName: "origin",
                        branchName: currentBranch,
                        pushedAt: Date()
                    )
                }
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func discardLocalChangesUnlocked(_ repo: RepoRecord) async throws {
        do {
            try await withRepositoryAccess(repo) { repository, _ in
                if let currentBranch = try? repository.branch.current,
                   let headCommit = currentBranch.target as? Commit {
                    try repository.reset(to: headCommit, mode: .hard)
                } else if let headReference = try? repository.HEAD,
                          let headCommit = headReference.target as? Commit {
                    try repository.reset(to: headCommit, mode: .hard)
                }

                let statuses = try repository.status()
                try self.removeUntrackedItems(in: repository, statuses: statuses)
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func resetToRemoteUnlocked(_ repo: RepoRecord) async throws -> SyncResult {
        let parsed = try SSHRemoteURL(parse: repo.remoteURL)
        try await evaluateHostTrust(parsed)
        let credential = try await credentialProvider.credential(for: parsed.host, username: parsed.user)

        do {
            return try await withRepositoryAccess(repo) { repository, _ in
                try await self.withSSHAuthentication(credential: credential) { authentication in
                    try await repository.fetch(
                        remote: repository.remote["origin"],
                        authentication: authentication
                    )

                    guard let remoteBranch = repository.branch["origin/\(repo.trackedBranch)", type: .remote] else {
                        return SyncResult(
                            state: .failed,
                            message: "Remote branch origin/\(repo.trackedBranch) not found."
                        )
                    }

                    if let localBranch = repository.branch[repo.trackedBranch, type: .local] {
                        try repository.switch(to: localBranch)
                    } else {
                        try repository.switch(to: remoteBranch)
                    }

                    guard let remoteCommit = remoteBranch.target as? Commit else {
                        return SyncResult(
                            state: .failed,
                            message: "Unable to resolve remote branch tip."
                        )
                    }

                    try repository.reset(to: remoteCommit, mode: .hard)
                    return SyncResult(
                        state: .success,
                        message: "Reset local branch to origin/\(repo.trackedBranch)."
                    )
                }
            }
        } catch let error as SwiftGitXError {
            throw map(error: error)
        }
    }

    private func withRepositoryAccess<T: Sendable>(
        _ repo: RepoRecord,
        operation: (Repository, URL) async throws -> T
    ) async throws -> T {
        try await withSecurityScopedAccess(
            directoryURL: URL(fileURLWithPath: repo.localPath, isDirectory: true),
            bookmarkData: repo.securityScopedBookmark
        ) { repositoryURL in
            guard self.fileManager.fileExists(atPath: repositoryURL.path) else {
                throw RepoError.ioFailure("Repository directory missing.")
            }

            let repository: Repository
            do {
                repository = try Repository.open(at: repositoryURL)
            } catch let error as SwiftGitXError {
                throw self.map(error: error)
            }

            return try await operation(repository, repositoryURL)
        }
    }

    private func loadCommitIdentity(from repository: Repository) throws -> RepoCommitIdentity? {
        let name = try configStringIfPresent("user.name", in: repository)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = try configStringIfPresent("user.email", in: repository)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let name, !name.isEmpty,
              let email, !email.isEmpty else {
            return nil
        }

        return RepoCommitIdentity(name: name, email: email)
    }

    private func configStringIfPresent(_ key: String, in repository: Repository) throws -> String? {
        do {
            return try repository.config.string(forKey: key)
        } catch let error {
            if error.code == .notFound {
                return nil
            }
            throw error
        }
    }

    private func stagePaths(in repository: Repository, paths: [String]) throws {
        let uniquePaths = Array(Set(paths))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !uniquePaths.isEmpty else {
            throw RepoError.nothingToStage
        }

        let workingDirectory = try repository.workingDirectory
        var existingPaths: [String] = []
        var deletedPaths: [String] = []

        for path in uniquePaths {
            let fileURL = workingDirectory.appendingPathComponent(path)
            if fileManager.fileExists(atPath: fileURL.path) {
                existingPaths.append(path)
            } else {
                deletedPaths.append(path)
            }
        }

        if !existingPaths.isEmpty {
            try repository.add(paths: existingPaths)
        }
        for path in deletedPaths {
            try? repository.remove(path: path)
        }
    }

    private func hasStagedChanges(_ statuses: [StatusEntry]) -> Bool {
        statuses.contains { entry in
            entry.status.contains { status in
                switch status {
                case .indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private func removeUntrackedItems(in repository: Repository, statuses: [StatusEntry]) throws {
        let untrackedPaths = Set(
            statuses
                .filter { $0.status.contains(.workingTreeNew) }
                .compactMap { path(for: $0) }
        )

        let sortedPaths = untrackedPaths.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth == rhsDepth {
                return lhs.count > rhs.count
            }
            return lhsDepth > rhsDepth
        }

        let workingDirectory = try repository.workingDirectory
        for path in sortedPaths {
            let itemURL = workingDirectory.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: itemURL.path) else {
                continue
            }
            try fileManager.removeItem(at: itemURL)
        }
    }

    private func makeLocalChanges(from statuses: [StatusEntry]) -> [RepoLocalChange] {
        statuses.compactMap { entry in
            guard let path = path(for: entry) else {
                return nil
            }

            let relevantStatuses = entry.status.filter { status in
                switch status {
                case .current, .ignored:
                    return false
                default:
                    return true
                }
            }

            guard !relevantStatuses.isEmpty else {
                return nil
            }

            return RepoLocalChange(
                path: path,
                kind: localChangeKind(for: relevantStatuses),
                stageState: localChangeStageState(for: relevantStatuses)
            )
        }
        .sorted { lhs, rhs in
            lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
    }

    private func localChangeKind(for statuses: [StatusEntry.Status]) -> RepoLocalChangeKind {
        if statuses.contains(.conflicted) {
            return .conflicted
        }
        if statuses.contains(.indexRenamed) || statuses.contains(.workingTreeRenamed) {
            return .renamed
        }
        if statuses.contains(.indexDeleted) || statuses.contains(.workingTreeDeleted) {
            return .deleted
        }
        if statuses.contains(.indexNew) || statuses.contains(.workingTreeNew) {
            return .added
        }
        if statuses.contains(.indexTypeChange) || statuses.contains(.workingTreeTypeChange) {
            return .typeChanged
        }
        if statuses.contains(.indexModified) ||
            statuses.contains(.workingTreeModified) ||
            statuses.contains(.workingTreeUnreadable) {
            return .modified
        }
        return .unknown
    }

    private func localChangeStageState(for statuses: [StatusEntry.Status]) -> RepoLocalChangeStageState {
        let hasIndexState = statuses.contains { status in
            switch status {
            case .indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange:
                return true
            default:
                return false
            }
        }

        let hasWorktreeState = statuses.contains { status in
            switch status {
            case .workingTreeNew, .workingTreeModified, .workingTreeDeleted, .workingTreeRenamed,
                    .workingTreeTypeChange, .workingTreeUnreadable:
                return true
            default:
                return false
            }
        }

        if statuses.contains(.conflicted) || (hasIndexState && hasWorktreeState) {
            return .both
        }
        if hasIndexState {
            return .staged
        }
        return .unstaged
    }

    private func path(for entry: StatusEntry) -> String? {
        if let indexPath = deltaPath(entry.index), !indexPath.isEmpty {
            return indexPath
        }
        if let workingTreePath = deltaPath(entry.workingTree), !workingTreePath.isEmpty {
            return workingTreePath
        }
        return nil
    }

    private func deltaPath(_ delta: Diff.Delta?) -> String? {
        guard let delta else {
            return nil
        }

        if !delta.newFile.path.isEmpty {
            return delta.newFile.path
        }
        if !delta.oldFile.path.isEmpty {
            return delta.oldFile.path
        }
        return nil
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

    private func makeProbeResult(from parsed: SSHRemoteURL) -> RemoteProbeResult {
        RemoteProbeResult(host: parsed.host, port: parsed.port, normalizedURL: parsed.normalized)
    }

    private func evaluateHostTrust(_ parsed: SSHRemoteURL) async throws {
        let fingerprint = syntheticHostFingerprint(host: parsed.host, port: parsed.port)
        _ = try await trustEvaluator.evaluate(
            host: parsed.host,
            port: parsed.port,
            presentedFingerprint: fingerprint,
            algorithm: "ed25519"
        )
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
        case .uncommitted:
            return .nothingToCommit
        case .unchanged:
            return .nothingToStage
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
