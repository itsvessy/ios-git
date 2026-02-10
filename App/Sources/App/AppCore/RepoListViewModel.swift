import Core
import Combine
import Foundation
import GitEngine
import SecurityEngine
import Storage

struct RepoSSHPreparation: Sendable {
    let host: String
    let normalizedRemoteURL: String
    let key: SSHKeyRecord
    let didGenerateKey: Bool
}

@MainActor
final class RepoListViewModel: ObservableObject {
    @Published private(set) var repos: [RepoRecord] = []
    @Published private(set) var sshKeys: [SSHKeyRecord] = []
    @Published private(set) var isAddingRepo = false
    @Published private(set) var syncingRepoIDs: Set<RepoID> = []
    @Published private(set) var activeGitActionRepoIDs: Set<RepoID> = []

    @Published var searchQuery = ""
    @Published var sortMode: RepoSortMode = .name
    @Published var stateFilter: RepoStateFilter = .all

    private let repoStore: RepoStore
    private let gitClient: GitClient
    private let logger: AppLogger
    private let keyManager: any SSHKeyManaging
    private let bannerCenter: AppBannerCenter

    init(
        repoStore: RepoStore,
        gitClient: GitClient,
        logger: AppLogger,
        keyManager: any SSHKeyManaging,
        bannerCenter: AppBannerCenter
    ) {
        self.repoStore = repoStore
        self.gitClient = gitClient
        self.logger = logger
        self.keyManager = keyManager
        self.bannerCenter = bannerCenter
    }

    var visibleRepos: [RepoRecord] {
        let filtered = repos.filter { repo in
            guard stateFilter.matches(state: repo.lastSyncState) else {
                return false
            }

            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return true
            }

            let lowered = query.lowercased()
            return repo.displayName.lowercased().contains(lowered)
                || repo.remoteURL.lowercased().contains(lowered)
                || repo.trackedBranch.lowercased().contains(lowered)
        }

        switch sortMode {
        case .name:
            return filtered.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .lastSync:
            return filtered.sorted { lhs, rhs in
                switch (lhs.lastSyncAt, rhs.lastSyncAt) {
                case let (left?, right?):
                    if left == right {
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
                    return left > right
                case (nil, nil):
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                }
            }
        case .syncState:
            return filtered.sorted { lhs, rhs in
                let lhsRank = syncRank(for: lhs.lastSyncState)
                let rhsRank = syncRank(for: rhs.lastSyncState)
                if lhsRank == rhsRank {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhsRank < rhsRank
            }
        }
    }

    func count(for filter: RepoStateFilter) -> Int {
        repos.filter { filter.matches(state: $0.lastSyncState) }.count
    }

    func repo(withID id: RepoID) -> RepoRecord? {
        repos.first(where: { $0.id == id })
    }

    func isSyncing(repoID: RepoID) -> Bool {
        syncingRepoIDs.contains(repoID)
    }

    func isGitActionInProgress(repoID: RepoID) -> Bool {
        activeGitActionRepoIDs.contains(repoID)
    }

    func refresh() async {
        do {
            repos = try await repoStore.listRepos()
        } catch {
            publish("Failed loading repositories: \(error.localizedDescription)", kind: .error)
            Task { await logger.log("Failed loading repos: \(error)", level: .error) }
        }
    }

    func prepareSSHForAddRepo(remoteURL: String, passphrase: String?) async throws -> RepoSSHPreparation {
        let probe = try await gitClient.prepareRemote(remoteURL)
        let didGenerateKey = try await ensureKeyForHost(probe.host, passphrase: passphrase)
        guard let key = try await repoStore.defaultKey(host: probe.host) else {
            throw RepoError.keyNotFound
        }
        sshKeys = try await repoStore.listKeys()

        return RepoSSHPreparation(
            host: probe.host,
            normalizedRemoteURL: probe.normalizedURL,
            key: key,
            didGenerateKey: didGenerateKey
        )
    }

    @discardableResult
    func addRepo(
        displayName: String,
        remoteURL: String,
        trackedBranch: String,
        autoSyncEnabled: Bool,
        cloneRootURL: URL? = nil,
        cloneRootBookmark: Data? = nil
    ) async -> Bool {
        isAddingRepo = true
        defer { isAddingRepo = false }

        do {
            let targetDirectory = cloneRootURL ?? repositoriesRoot()
            let request = CloneRequest(
                displayName: displayName,
                remoteURL: remoteURL,
                targetDirectory: targetDirectory,
                targetDirectoryBookmark: cloneRootBookmark,
                trackedBranch: trackedBranch,
                autoSyncEnabled: autoSyncEnabled
            )

            let repo = try await gitClient.clone(request)
            try await repoStore.upsert(repo)
            try await reloadStateFromStore()

            publish("Added \(repo.displayName).", kind: .success)
            await logger.log("Cloned repo \(repo.displayName) at \(repo.localPath)")
            return true
        } catch {
            do {
                try await reloadStateFromStore()
            } catch {
                await logger.log("State refresh after add failure failed: \(error)", level: .error)
            }

            if let repoError = error as? RepoError,
               case .syncBlocked = repoError {
                publish(
                    "SSH auth failed. The repository was not added.",
                    kind: .error
                )
            } else {
                publish(error.localizedDescription, kind: .error)
            }

            await logger.log("Add repo failed: \(error)", level: .error)
            return false
        }
    }

    func sync(repo: RepoRecord, trigger: SyncTrigger = .manual) async {
        syncingRepoIDs.insert(repo.id)
        defer { syncingRepoIDs.remove(repo.id) }

        var working = repo
        working.lastSyncState = .syncing
        working.lastErrorMessage = nil

        do {
            try await repoStore.upsert(working)
            repos = try await repoStore.listRepos()

            let result = try await gitClient.sync(repo, trigger: trigger)
            try await repoStore.setSyncResult(repoID: repo.id, result: result)
            repos = try await repoStore.listRepos()

            if let message = result.message, !message.isEmpty {
                publish(message, kind: result.state == .success ? .success : .info)
            } else if result.state == .success {
                publish("Sync completed.", kind: .success)
            }

            await logger.log("Sync complete for \(repo.displayName): \(result.state.rawValue)")
        } catch {
            let mapped = map(error: error)
            do {
                try await repoStore.setSyncResult(repoID: repo.id, result: mapped)
                repos = try await repoStore.listRepos()
            } catch {
                await logger.log("Failed persisting sync error: \(error)", level: .error)
            }

            publish(mapped.message ?? "Sync failed.", kind: .error)
            await logger.log("Sync failed for \(repo.displayName): \(mapped.message ?? "unknown")", level: .warning)
        }
    }

    func setAutoSync(repo: RepoRecord, enabled: Bool) async {
        var updated = repo
        updated.autoSyncEnabled = enabled
        do {
            try await repoStore.upsert(updated)
            repos = try await repoStore.listRepos()
        } catch {
            publish(error.localizedDescription, kind: .error)
        }
    }

    func loadLocalChanges(repo: RepoRecord) async -> [RepoLocalChange] {
        do {
            return try await gitClient.listLocalChanges(repo)
        } catch {
            publish("Could not load local changes: \(error.localizedDescription)", kind: .error)
            return []
        }
    }

    func stage(repo: RepoRecord, paths: [String]) async -> Bool {
        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            try await gitClient.stage(repo, paths: paths)
            publish("Staged selected changes.", kind: .success)
            return true
        } catch {
            publish(error.localizedDescription, kind: .error)
            return false
        }
    }

    func stageAll(repo: RepoRecord) async -> Bool {
        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            try await gitClient.stageAll(repo)
            publish("Staged all local changes.", kind: .success)
            return true
        } catch {
            publish(error.localizedDescription, kind: .error)
            return false
        }
    }

    func loadCommitIdentity(repo: RepoRecord) async -> RepoCommitIdentity? {
        do {
            return try await gitClient.loadCommitIdentity(repo)
        } catch {
            publish("Could not load commit identity: \(error.localizedDescription)", kind: .error)
            return nil
        }
    }

    func saveCommitIdentity(repo: RepoRecord, name: String, email: String) async -> Bool {
        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            let identity = RepoCommitIdentity(name: name, email: email)
            try await gitClient.saveCommitIdentity(identity, for: repo)
            publish("Saved commit identity.", kind: .success)
            return true
        } catch {
            publish(error.localizedDescription, kind: .error)
            return false
        }
    }

    func commit(repo: RepoRecord, message: String) async -> Bool {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            publish(RepoError.invalidCommitMessage.localizedDescription, kind: .error)
            return false
        }

        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            let result = try await gitClient.commit(repo, message: trimmedMessage)
            try await clearBlockedState(repoID: repo.id)
            let shortID = String(result.commitID.prefix(7))
            publish("Committed \(shortID).", kind: .success)
            await logger.log("Commit complete for \(repo.displayName): \(result.commitID)")
            return true
        } catch {
            publish(error.localizedDescription, kind: .error)
            await logger.log("Commit failed for \(repo.displayName): \(error)", level: .warning)
            return false
        }
    }

    func push(repo: RepoRecord) async -> Bool {
        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            let result = try await gitClient.push(repo)
            try await clearBlockedState(repoID: repo.id)
            publish("Pushed \(result.branchName) to \(result.remoteName).", kind: .success)
            await logger.log("Push complete for \(repo.displayName) -> \(result.remoteName)/\(result.branchName)")
            return true
        } catch {
            publish(error.localizedDescription, kind: .error)
            await logger.log("Push failed for \(repo.displayName): \(error)", level: .warning)
            return false
        }
    }

    func quickAddCommitPush(repo: RepoRecord, message: String) async -> Bool {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            publish(RepoError.invalidCommitMessage.localizedDescription, kind: .error)
            return false
        }

        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            try await gitClient.stageAll(repo)
            let commitResult = try await gitClient.commit(repo, message: trimmedMessage)
            let pushResult = try await gitClient.push(repo)
            try await clearBlockedState(repoID: repo.id)

            let shortID = String(commitResult.commitID.prefix(7))
            publish(
                "Committed \(shortID) and pushed \(pushResult.branchName) to \(pushResult.remoteName).",
                kind: .success
            )
            await logger.log("Quick add+commit+push complete for \(repo.displayName): \(commitResult.commitID)")
            return true
        } catch {
            publish(error.localizedDescription, kind: .error)
            await logger.log("Quick add+commit+push failed for \(repo.displayName): \(error)", level: .warning)
            return false
        }
    }

    func discardLocalChanges(repo: RepoRecord) async {
        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            try await gitClient.discardLocalChanges(repo)
            try await clearBlockedState(repoID: repo.id)
            publish("Discarded local changes for \(repo.displayName).", kind: .success)
            await logger.log("Discarded local changes for \(repo.displayName)")
        } catch {
            publish("Could not discard local changes: \(error.localizedDescription)", kind: .error)
            await logger.log("Discard local changes failed for \(repo.displayName): \(error)", level: .warning)
        }
    }

    func resetToRemote(repo: RepoRecord) async {
        beginGitAction(for: repo.id)
        defer { endGitAction(for: repo.id) }

        do {
            let result = try await gitClient.resetToRemote(repo)
            if result.state == .success {
                try await clearBlockedState(repoID: repo.id)
                publish(result.message ?? "Reset to remote completed.", kind: .success)
            } else {
                publish(result.message ?? "Reset to remote failed.", kind: .error)
            }
            await logger.log("Reset-to-remote for \(repo.displayName): \(result.state.rawValue)")
        } catch {
            publish("Could not reset to remote: \(error.localizedDescription)", kind: .error)
            await logger.log("Reset-to-remote failed for \(repo.displayName): \(error)", level: .warning)
        }
    }

    func deleteRepo(repo: RepoRecord, removeFiles: Bool) async {
        do {
            let didDeleteFiles: Bool
            if removeFiles {
                didDeleteFiles = try withRepoAccess(repo) { repoURL in
                    guard FileManager.default.fileExists(atPath: repoURL.path) else {
                        return false
                    }
                    try FileManager.default.removeItem(at: repoURL)
                    return true
                }
            } else {
                didDeleteFiles = false
            }

            try await repoStore.delete(repoID: repo.id)
            repos = try await repoStore.listRepos()

            if removeFiles {
                publish(
                    didDeleteFiles
                        ? "Removed \(repo.displayName) and deleted local files."
                        : "Removed \(repo.displayName). Local files were already missing.",
                    kind: .success
                )
            } else {
                publish("Removed \(repo.displayName) from GitPhone.", kind: .success)
            }

            Task {
                if removeFiles {
                    await logger.log("Deleted repo \(repo.displayName) (removeFiles=\(didDeleteFiles))")
                } else {
                    await logger.log("Deleted repo \(repo.displayName) (metadata only)")
                }
            }
        } catch {
            publish("Could not delete \(repo.displayName): \(error.localizedDescription)", kind: .error)
            Task { await logger.log("Delete repo failed: \(error)", level: .error) }
        }
    }

    private func publish(_ message: String, kind: RepoBannerMessage.Kind) {
        bannerCenter.show(RepoBannerMessage(text: message, kind: kind))
    }

    private func syncRank(for state: RepoSyncState) -> Int {
        switch state {
        case .syncing:
            return 0
        case .failed:
            return 1
        case .authFailed:
            return 2
        case .blockedDirty, .blockedDiverged, .hostMismatch:
            return 3
        case .networkDeferred:
            return 4
        case .idle:
            return 5
        case .success:
            return 6
        }
    }

    private func beginGitAction(for repoID: RepoID) {
        activeGitActionRepoIDs.insert(repoID)
    }

    private func endGitAction(for repoID: RepoID) {
        activeGitActionRepoIDs.remove(repoID)
    }

    private func clearBlockedState(repoID: RepoID) async throws {
        guard var repo = try await repoStore.repo(id: repoID) else {
            return
        }

        repo.lastSyncState = .idle
        repo.lastErrorMessage = nil
        try await repoStore.upsert(repo)
        repos = try await repoStore.listRepos()
    }

    private func ensureKeyForHost(_ host: String, passphrase: String?) async throws -> Bool {
        if let _ = try await repoStore.defaultKey(host: host) {
            return false
        }

        let generated = try keyManager.generateKey(
            host: host,
            label: "Default key for \(host)",
            preferredAlgorithm: .ed25519,
            passphrase: passphrase
        )
        try await repoStore.saveKey(generated.record, isHostDefault: true)
        return true
    }

    private func reloadStateFromStore() async throws {
        repos = try await repoStore.listRepos()
    }

    private func repositoriesRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = documents.appendingPathComponent("Repositories", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func withRepoAccess<T>(_ repo: RepoRecord, operation: (URL) throws -> T) throws -> T {
        let repoURL: URL
        var stopAccess: (() -> Void)?

        if let bookmarkData = repo.securityScopedBookmark {
            var isStale = false
            do {
                repoURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw RepoError.ioFailure("Could not resolve folder permission bookmark.")
            }
            _ = isStale
            let started = repoURL.startAccessingSecurityScopedResource()
            stopAccess = {
                if started {
                    repoURL.stopAccessingSecurityScopedResource()
                }
            }
        } else {
            repoURL = URL(fileURLWithPath: repo.localPath, isDirectory: true)
        }

        defer {
            stopAccess?()
        }
        return try operation(repoURL)
    }

    private func map(error: Error) -> SyncResult {
        guard let repoError = error as? RepoError else {
            return SyncResult(state: .failed, message: error.localizedDescription)
        }

        switch repoError {
        case .dirtyWorkingTree:
            return SyncResult(state: .blockedDirty, message: repoError.localizedDescription)
        case .divergedBranch:
            return SyncResult(state: .blockedDiverged, message: repoError.localizedDescription)
        case .hostMismatch:
            return SyncResult(state: .hostMismatch, message: repoError.localizedDescription)
        case .keyNotFound, .keychainFailure:
            return SyncResult(state: .authFailed, message: repoError.localizedDescription)
        default:
            return SyncResult(state: .failed, message: repoError.localizedDescription)
        }
    }
}
