import Core
import Foundation
import SecurityEngine
import Storage
import SwiftData
import XCTest
@testable import GitPhone

private struct NoopGitClient: GitClient {
    func prepareRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        try await Task.sleep(nanoseconds: 1)
        return RemoteProbeResult(host: "github.com", port: 22, normalizedURL: remoteURL)
    }

    func clone(_ request: CloneRequest) async throws -> RepoRecord {
        throw RepoError.ioFailure("not used in tests")
    }

    func sync(_ repo: RepoRecord, trigger: SyncTrigger) async throws -> SyncResult {
        SyncResult(state: .success, message: "ok")
    }

    func probeRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        try await Task.sleep(nanoseconds: 1)
        return RemoteProbeResult(host: "github.com", port: 22, normalizedURL: remoteURL)
    }
}

@MainActor
final class RepoHubFilteringSortingTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!
    private var viewModel: RepoListViewModel!

    override func setUpWithError() throws {
        let schema = Schema(StorageSchema.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        store = RepoStore(container: container)
        viewModel = RepoListViewModel(
            repoStore: store,
            gitClient: NoopGitClient(),
            logger: AppLogger(),
            keyManager: SSHKeyManager(),
            bannerCenter: AppBannerCenter()
        )
    }

    override func tearDownWithError() throws {
        viewModel = nil
        store = nil
        container = nil
    }

    func testSearchAndFilterReturnsExpectedRepos() async throws {
        try await store.upsert(makeRepo(name: "Alpha", state: .success))
        try await store.upsert(makeRepo(name: "Beta", state: .failed))
        try await store.upsert(makeRepo(name: "Gamma", state: .blockedDirty))

        await viewModel.refresh()

        viewModel.searchQuery = "alp"
        XCTAssertEqual(viewModel.visibleRepos.map(\.displayName), ["Alpha"])

        viewModel.searchQuery = ""
        viewModel.stateFilter = .failed
        XCTAssertEqual(viewModel.visibleRepos.map(\.displayName), ["Beta"])
    }

    func testSortByLastSyncPutsNewestFirst() async throws {
        try await store.upsert(makeRepo(name: "Old", state: .success, lastSyncAt: Date(timeIntervalSince1970: 100)))
        try await store.upsert(makeRepo(name: "New", state: .success, lastSyncAt: Date(timeIntervalSince1970: 200)))
        try await store.upsert(makeRepo(name: "Never", state: .idle, lastSyncAt: nil))

        await viewModel.refresh()
        viewModel.sortMode = .lastSync

        XCTAssertEqual(viewModel.visibleRepos.map(\.displayName), ["New", "Old", "Never"])
    }

    func testSortBySyncStatePrioritizesActionableStates() async throws {
        try await store.upsert(makeRepo(name: "Synced", state: .success))
        try await store.upsert(makeRepo(name: "Failed", state: .failed))
        try await store.upsert(makeRepo(name: "Syncing", state: .syncing))

        await viewModel.refresh()
        viewModel.sortMode = .syncState

        XCTAssertEqual(viewModel.visibleRepos.map(\.displayName), ["Syncing", "Failed", "Synced"])
    }

    func testRefreshLoadsReposWithoutPrefetchingKeys() async throws {
        let key = SSHKeyRecord(
            id: UUID(),
            host: "github.com",
            label: "Default",
            algorithm: "ed25519",
            keySource: "generated",
            publicKeyOpenSSH: "ssh-ed25519 AAA",
            keychainPrivateRef: "private.\(UUID().uuidString)",
            keychainPassphraseRef: nil
        )
        try await store.saveKey(key, isHostDefault: true)
        try await store.upsert(makeRepo(name: "Alpha", state: .idle))

        await viewModel.refresh()

        XCTAssertEqual(viewModel.repos.count, 1)
        XCTAssertTrue(viewModel.sshKeys.isEmpty)
    }

    private func makeRepo(
        name: String,
        state: RepoSyncState,
        lastSyncAt: Date? = nil
    ) -> RepoRecord {
        RepoRecord(
            id: RepoID(),
            displayName: name,
            remoteURL: "git@github.com:owner/\(name.lowercased()).git",
            localPath: "/tmp/\(name.lowercased())",
            trackedBranch: "main",
            autoSyncEnabled: true,
            lastSyncAt: lastSyncAt,
            lastSyncState: state,
            lastErrorMessage: nil
        )
    }
}
