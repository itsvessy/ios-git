import Core
import Foundation
import GitEngine
import SecurityEngine
import Storage
import SwiftData

@MainActor
final class RepoListViewModel: ObservableObject {
    @Published private(set) var repos: [RepoRecord] = []
    @Published private(set) var sshKeys: [SSHKeyRecord] = []
    @Published var isPresentingAddRepo = false
    @Published var isPresentingPublicKeys = false
    @Published var isWorking = false
    @Published var statusMessage: String?

    private let repoStore: RepoStore
    private let gitClient: GitClient
    private let logger: AppLogger
    private let keyManager: SSHKeyManager

    init(repoStore: RepoStore, gitClient: GitClient, logger: AppLogger, keyManager: SSHKeyManager) {
        self.repoStore = repoStore
        self.gitClient = gitClient
        self.logger = logger
        self.keyManager = keyManager
    }

    func refresh() {
        do {
            repos = try repoStore.listRepos()
            sshKeys = try repoStore.listKeys()
        } catch {
            statusMessage = error.localizedDescription
            Task { await logger.log("Failed loading repos: \(error)", level: .error) }
        }
    }

    func addRepo(
        displayName: String,
        remoteURL: String,
        trackedBranch: String,
        autoSyncEnabled: Bool,
        generateKeyIfNeeded: Bool,
        passphrase: String?,
        cloneRootURL: URL? = nil,
        cloneRootBookmark: Data? = nil
    ) async {
        isWorking = true
        defer { isWorking = false }
        var generatedNewKey = false

        do {
            let parsed = try SSHRemoteURL(parse: remoteURL)
            if generateKeyIfNeeded {
                generatedNewKey = try ensureKeyForHost(parsed.host, passphrase: passphrase)
                if generatedNewKey {
                    sshKeys = try repoStore.listKeys()
                }
            }

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
            try repoStore.upsert(repo)
            repos = try repoStore.listRepos()
            sshKeys = try repoStore.listKeys()
            if generatedNewKey {
                statusMessage = "Added \(repo.displayName). New SSH key created for \(parsed.host)."
            } else {
                statusMessage = "Added \(repo.displayName)."
            }
            await logger.log("Cloned repo \(repo.displayName) at \(repo.localPath)")
        } catch {
            do {
                repos = try repoStore.listRepos()
                sshKeys = try repoStore.listKeys()
            } catch {
                await logger.log("State refresh after add failure failed: \(error)", level: .error)
            }
            if let repoError = error as? RepoError,
               case .syncBlocked = repoError {
                if generatedNewKey {
                    statusMessage = "SSH auth failed. A key was created, but the repository was not added yet. Add the key on your Git host, then use Add Repository again."
                } else {
                    statusMessage = "SSH auth failed. The repository was not added. Verify key access, then use Add Repository again."
                }
            } else {
                statusMessage = error.localizedDescription
            }
            await logger.log("Add repo failed: \(error)", level: .error)
        }
    }

    func sync(repo: RepoRecord, trigger: SyncTrigger = .manual) async {
        isWorking = true
        defer { isWorking = false }

        var working = repo
        working.lastSyncState = .syncing
        working.lastErrorMessage = nil

        do {
            try repoStore.upsert(working)
            repos = try repoStore.listRepos()

            let result = try await gitClient.sync(repo, trigger: trigger)
            try repoStore.setSyncResult(repoID: repo.id, result: result)
            repos = try repoStore.listRepos()
            statusMessage = result.message ?? "Sync completed."
            await logger.log("Sync complete for \(repo.displayName): \(result.state.rawValue)")
        } catch {
            let mapped = map(error: error)
            do {
                try repoStore.setSyncResult(repoID: repo.id, result: mapped)
                repos = try repoStore.listRepos()
            } catch {
                await logger.log("Failed persisting sync error: \(error)", level: .error)
            }

            statusMessage = mapped.message
            await logger.log("Sync failed for \(repo.displayName): \(mapped.message ?? "unknown")", level: .warning)
        }
    }

    func setAutoSync(repo: RepoRecord, enabled: Bool) {
        var updated = repo
        updated.autoSyncEnabled = enabled
        do {
            try repoStore.upsert(updated)
            repos = try repoStore.listRepos()
            sshKeys = try repoStore.listKeys()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func discardLocalChanges(repo: RepoRecord) {
        do {
            try withRepoAccess(repo) { repoURL in
                let marker = repoURL.appendingPathComponent(".gitphone-dirty")
                if FileManager.default.fileExists(atPath: marker.path) {
                    try FileManager.default.removeItem(at: marker)
                }
            }
            statusMessage = "Local dirty marker cleared for \(repo.displayName)."
        } catch {
            statusMessage = "Could not clear local dirty marker: \(error.localizedDescription)"
        }
    }

    func resolveDivergedByReset(repo: RepoRecord) {
        do {
            try withRepoAccess(repo) { repoURL in
                let marker = repoURL.appendingPathComponent(".gitphone-diverged")
                if FileManager.default.fileExists(atPath: marker.path) {
                    try FileManager.default.removeItem(at: marker)
                }
            }
            statusMessage = "Diverged marker cleared for \(repo.displayName)."
        } catch {
            statusMessage = "Could not clear diverged marker: \(error.localizedDescription)"
        }
    }

    func deleteRepo(repo: RepoRecord, removeFiles: Bool) {
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

            try repoStore.delete(repoID: repo.id)
            repos = try repoStore.listRepos()
            sshKeys = try repoStore.listKeys()

            if removeFiles {
                statusMessage = didDeleteFiles
                    ? "Removed \(repo.displayName) and deleted local files."
                    : "Removed \(repo.displayName). Local files were already missing."
            } else {
                statusMessage = "Removed \(repo.displayName) from GitPhone."
            }

            Task {
                if removeFiles {
                    await logger.log("Deleted repo \(repo.displayName) (removeFiles=\(didDeleteFiles))")
                } else {
                    await logger.log("Deleted repo \(repo.displayName) (metadata only)")
                }
            }
        } catch {
            statusMessage = "Could not delete \(repo.displayName): \(error.localizedDescription)"
            Task { await logger.log("Delete repo failed: \(error)", level: .error) }
        }
    }

    private func ensureKeyForHost(_ host: String, passphrase: String?) throws -> Bool {
        if let _ = try repoStore.defaultKey(host: host) {
            return false
        }

        let generated = try keyManager.generateKey(
            host: host,
            label: "Default key for \(host)",
            preferredAlgorithm: .ed25519,
            passphrase: passphrase
        )
        try repoStore.saveKey(generated.record, isHostDefault: true)
        return true
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
