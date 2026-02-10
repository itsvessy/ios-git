import BackgroundTasks
import Core
import Foundation

public final class BackgroundSyncCoordinator: @unchecked Sendable {
    public static let taskIdentifier = "com.vessy.GitPhone.sync"

    private let gitClient: GitClient
    private let loadEligibleRepos: () async throws -> [RepoRecord]
    private let persistResult: (_ repoID: RepoID, _ result: SyncResult) async -> Void

    public init(
        gitClient: GitClient,
        loadEligibleRepos: @escaping () async throws -> [RepoRecord],
        persistResult: @escaping (_ repoID: RepoID, _ result: SyncResult) async -> Void
    ) {
        self.gitClient = gitClient
        self.loadEligibleRepos = loadEligibleRepos
        self.persistResult = persistResult
    }

    public func register() {
        // Register from app target when using the production background pipeline.
    }

    public func scheduleNext(afterHours: Int = 6) {
        _ = afterHours
        // Scheduling is a no-op in this scaffold build.
    }

    public func handle(task: BGAppRefreshTask) {
        scheduleNext()
        task.setTaskCompleted(success: true)
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

    private func isBackgroundNetworkAllowed() async -> Bool {
        // Network policy is finalized in app-level sync preflight for the real Git backend.
        true
    }
}
