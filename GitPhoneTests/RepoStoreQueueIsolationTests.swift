import Core
import Foundation
import Storage
import SwiftData
import XCTest

@MainActor
final class RepoStoreQueueIsolationTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!

    override func setUpWithError() throws {
        let schema = Schema(StorageSchema.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        store = RepoStore(container: container)
    }

    override func tearDownWithError() throws {
        store = nil
        container = nil
    }

    func testStoreOperationsSucceedFromDetachedTasks() async throws {
        let store = try XCTUnwrap(store)
        let repo = RepoRecord(
            id: RepoID(),
            displayName: "Detached",
            remoteURL: "git@github.com:owner/detached.git",
            localPath: "/tmp/detached",
            trackedBranch: "main",
            autoSyncEnabled: true
        )

        try await Task.detached {
            try await store.upsert(repo)
        }.value

        let repos = try await Task.detached {
            try await store.listRepos()
        }.value

        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos.first?.displayName, "Detached")
    }

    func testConcurrentDetachedWritesRemainConsistent() async throws {
        let store = try XCTUnwrap(store)
        let inserts = (0..<20).map { index in
            Task.detached {
                let repo = RepoRecord(
                    id: RepoID(),
                    displayName: "Repo-\(index)",
                    remoteURL: "git@github.com:owner/repo-\(index).git",
                    localPath: "/tmp/repo-\(index)",
                    trackedBranch: "main",
                    autoSyncEnabled: true
                )
                try await store.upsert(repo)
            }
        }

        for task in inserts {
            try await task.value
        }

        let repos = try await store.listRepos()
        XCTAssertEqual(repos.count, 20)
    }

    func testStoreWorksFromMainActorCaller() async throws {
        let store = try XCTUnwrap(store)
        let repo = RepoRecord(
            id: RepoID(),
            displayName: "MainActor",
            remoteURL: "git@github.com:owner/main-actor.git",
            localPath: "/tmp/main-actor",
            trackedBranch: "main",
            autoSyncEnabled: true
        )

        try await store.upsert(repo)

        let loaded = try await store.listRepos()
        XCTAssertTrue(loaded.contains(where: { $0.displayName == "MainActor" }))
    }
}
