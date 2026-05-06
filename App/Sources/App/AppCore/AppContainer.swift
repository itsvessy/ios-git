import BackgroundSync
import Core
import Foundation
import GitEngine
import SecurityEngine
import Storage
import SwiftData

@MainActor
final class AppContainer: ObservableObject {
    let modelContainer: ModelContainer
    let repoStore: RepoStore
    let logger: AppLogger
    let keyManager: any SSHKeyManaging
    let appLock: AppLockCoordinator
    let hostTrustPrompter: HostTrustPrompter
    let bannerCenter: AppBannerCenter
    let keyboardWarmupCoordinator: KeyboardWarmupCoordinator
    let viewModel: RepoListViewModel
    let securityCenterViewModel: SecurityCenterViewModel

    private let backgroundSyncCoordinator: BackgroundSyncCoordinator

    init() {
        let schema = Schema(StorageSchema.models)
        let storeURL: URL
        do {
            storeURL = try PersistenceStoreBootstrap().prepareStoreURL()
        } catch {
            fatalError("Failed to prepare persistence store directory: \(error)")
        }

        let config = ModelConfiguration(url: storeURL)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to initialize persistent store at \(storeURL.path): \(error)")
        }
        repoStore = RepoStore(container: modelContainer)
        logger = AppLogger()
        keyManager = SSHKeyManager()
        appLock = AppLockCoordinator(relockInterval: 30 * 60)
        hostTrustPrompter = HostTrustPrompter()
        bannerCenter = AppBannerCenter()
        keyboardWarmupCoordinator = KeyboardWarmupCoordinator()

        if ProcessInfo.processInfo.arguments.contains("UITEST_BYPASS_LOCK") {
            appLock.markUnlocked()
        }

        if ProcessInfo.processInfo.arguments.contains("UITEST_SEED_REPO") {
            let group = DispatchGroup()
            group.enter()
            Task.detached(priority: .userInitiated) { [repoStore, logger] in
                defer { group.leave() }
                do {
                    let existing = try await repoStore.listRepos()
                    guard existing.isEmpty else {
                        return
                    }

                    let tempRoot = FileManager.default.temporaryDirectory
                        .appendingPathComponent("CommitSyncUITestSeed", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

                    let seededRepo = RepoRecord(
                        id: RepoID(),
                        displayName: "ui-test",
                        remoteURL: "ssh://git@github.com:22/example/ui-test.git",
                        localPath: tempRoot.path,
                        trackedBranch: "main",
                        autoSyncEnabled: true,
                        lastSyncAt: nil,
                        lastSyncState: .idle,
                        lastErrorMessage: nil
                    )
                    try await repoStore.upsert(seededRepo)
                } catch {
                    await logger.log("UITest repo seed failed: \(error)", level: .warning)
                }
            }
            group.wait()
        }

        let trustEvaluator = FingerprintPinningPolicy(
            lookup: { [repoStore] host, port, algorithm in
                try await repoStore.fingerprint(host: host, port: port, algorithm: algorithm)
            },
            persist: { [repoStore] record in
                try await repoStore.saveFingerprint(record)
            },
            prompt: { [hostTrustPrompter] host, fingerprint, algorithm in
                await hostTrustPrompter.requestApproval(host: host, fingerprint: fingerprint, algorithm: algorithm)
            }
        )

        let credentialProvider = StoreCredentialProvider(
            lookupKey: { [repoStore] host in
                try await repoStore.defaultKey(host: host)
            },
            keyManager: keyManager
        )

        let gitClient = FileSystemGitClient(
            trustEvaluator: trustEvaluator,
            credentialProvider: credentialProvider
        )

        viewModel = RepoListViewModel(
            repoStore: repoStore,
            gitClient: gitClient,
            logger: logger,
            keyManager: keyManager,
            bannerCenter: bannerCenter
        )

        securityCenterViewModel = SecurityCenterViewModel(
            repoStore: repoStore,
            keyManager: keyManager,
            logger: logger,
            appLock: appLock,
            bannerCenter: bannerCenter
        )

        backgroundSyncCoordinator = BackgroundSyncCoordinator(
            gitClient: gitClient,
            loadEligibleRepos: { [repoStore] in
                try await repoStore.listRepos()
            },
            persistResult: { [repoStore] repoID, result in
                try? await repoStore.setSyncResult(repoID: repoID, result: result)
            }
        )

        backgroundSyncCoordinator.register()
        backgroundSyncCoordinator.scheduleNext(afterHours: 6)
    }
}
