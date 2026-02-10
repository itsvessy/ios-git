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
    let keyManager: SSHKeyManager
    let appLock: AppLockCoordinator
    let hostTrustPrompter: HostTrustPrompter
    let viewModel: RepoListViewModel

    private let backgroundSyncCoordinator: BackgroundSyncCoordinator

    init() {
        let schema = Schema(StorageSchema.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        modelContainer = try! ModelContainer(for: schema, configurations: config)
        repoStore = RepoStore(context: modelContainer.mainContext)
        logger = AppLogger()
        keyManager = SSHKeyManager()
        appLock = AppLockCoordinator(relockInterval: 30 * 60)
        hostTrustPrompter = HostTrustPrompter()

        let trustEvaluator = FingerprintPinningPolicy(
            lookup: { [repoStore] host, port, algorithm in
                try await MainActor.run {
                    try repoStore.fingerprint(host: host, port: port, algorithm: algorithm)
                }
            },
            persist: { [repoStore] record in
                try await MainActor.run {
                    try repoStore.saveFingerprint(record)
                }
            },
            prompt: { [hostTrustPrompter] host, fingerprint, algorithm in
                await hostTrustPrompter.requestApproval(host: host, fingerprint: fingerprint, algorithm: algorithm)
            }
        )

        let credentialProvider = StoreCredentialProvider(
            lookupKey: { [repoStore] host in
                try await MainActor.run {
                    try repoStore.defaultKey(host: host)
                }
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
            keyManager: keyManager
        )

        backgroundSyncCoordinator = BackgroundSyncCoordinator(
            gitClient: gitClient,
            loadEligibleRepos: { [repoStore] in
                try await MainActor.run {
                    try repoStore.listRepos()
                }
            },
            persistResult: { [repoStore] repoID, result in
                try? await MainActor.run {
                    try repoStore.setSyncResult(repoID: repoID, result: result)
                }
            }
        )

        backgroundSyncCoordinator.register()
        backgroundSyncCoordinator.scheduleNext(afterHours: 6)
    }
}
