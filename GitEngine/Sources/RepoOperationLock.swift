import Core
import Foundation

public actor RepoOperationLock {
    private var activeLocks: Set<RepoID> = []

    public init() {}

    public func withLock<T: Sendable>(repoID: RepoID, operation: () async throws -> T) async throws -> T {
        while activeLocks.contains(repoID) {
            try await Task.sleep(for: .milliseconds(150))
        }

        activeLocks.insert(repoID)
        defer { activeLocks.remove(repoID) }
        return try await operation()
    }
}
