import Core
import Foundation

public actor RepoOperationLock {
    private var activeLocks: Set<RepoID> = []

    public init() {}

    public func lock(repoID: RepoID) async {
        while activeLocks.contains(repoID) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        activeLocks.insert(repoID)
    }

    public func unlock(repoID: RepoID) {
        activeLocks.remove(repoID)
    }

    public func withLock<T: Sendable>(repoID: RepoID, operation: () async throws -> T) async throws -> T {
        await lock(repoID: repoID)
        defer { unlock(repoID: repoID) }
        return try await operation()
    }
}
