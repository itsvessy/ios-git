import Core
import Foundation
import SecurityEngine
import Storage
import SwiftData
import XCTest
@testable import GitPhone

private struct NoopKeyManager: SSHKeyManaging {
    func generateKey(
        host: String,
        label: String,
        preferredAlgorithm: SSHKeyAlgorithm,
        passphrase: String?
    ) throws -> GeneratedSSHKey {
        throw RepoError.keychainFailure("not used in tests")
    }

    func loadPrivateKey(reference: String, prompt: String) throws -> Data {
        throw RepoError.keychainFailure("not used in tests")
    }

    func loadPassphrase(reference: String, prompt: String) throws -> String {
        throw RepoError.keychainFailure("not used in tests")
    }

    func deleteMaterial(privateRef: String, passphraseRef: String?) throws {}
}

private actor RecordingGitClient: GitClient {
    enum Call: Equatable {
        case stage(paths: [String])
        case stageAll
        case saveIdentity(name: String, email: String)
        case commit(message: String)
        case push
        case discard
        case resetToRemote
    }

    private(set) var calls: [Call] = []
    private var identity: RepoCommitIdentity?
    private let requireIdentityBeforeCommit: Bool

    init(requireIdentityBeforeCommit: Bool = false) {
        self.requireIdentityBeforeCommit = requireIdentityBeforeCommit
    }

    func prepareRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        RemoteProbeResult(host: "github.com", port: 22, normalizedURL: remoteURL)
    }

    func clone(_ request: CloneRequest) async throws -> RepoRecord {
        throw RepoError.ioFailure("not used in tests")
    }

    func sync(_ repo: RepoRecord, trigger: SyncTrigger) async throws -> SyncResult {
        SyncResult(state: .success, message: "ok")
    }

    func probeRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        RemoteProbeResult(host: "github.com", port: 22, normalizedURL: remoteURL)
    }

    func listLocalChanges(_ repo: RepoRecord) async throws -> [RepoLocalChange] {
        []
    }

    func stage(_ repo: RepoRecord, paths: [String]) async throws {
        calls.append(.stage(paths: paths))
    }

    func stageAll(_ repo: RepoRecord) async throws {
        calls.append(.stageAll)
    }

    func loadCommitIdentity(_ repo: RepoRecord) async throws -> RepoCommitIdentity? {
        identity
    }

    func saveCommitIdentity(_ identity: RepoCommitIdentity, for repo: RepoRecord) async throws {
        calls.append(.saveIdentity(name: identity.name, email: identity.email))
        self.identity = identity
    }

    func commit(_ repo: RepoRecord, message: String) async throws -> RepoCommitResult {
        calls.append(.commit(message: message))
        if requireIdentityBeforeCommit, identity == nil {
            throw RepoError.commitIdentityMissing
        }
        return RepoCommitResult(commitID: "deadbeef", message: message)
    }

    func push(_ repo: RepoRecord) async throws -> RepoPushResult {
        calls.append(.push)
        return RepoPushResult(remoteName: "origin", branchName: repo.trackedBranch)
    }

    func discardLocalChanges(_ repo: RepoRecord) async throws {
        calls.append(.discard)
    }

    func resetToRemote(_ repo: RepoRecord) async throws -> SyncResult {
        calls.append(.resetToRemote)
        return SyncResult(state: .success, message: "reset complete")
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

@MainActor
final class RepoListGitActionsTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!
    private var bannerCenter: AppBannerCenter!

    override func setUpWithError() throws {
        let schema = Schema(StorageSchema.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        store = RepoStore(container: container)
        bannerCenter = AppBannerCenter()
    }

    override func tearDownWithError() throws {
        bannerCenter = nil
        store = nil
        container = nil
    }

    func testQuickFlowRunsStageThenCommitThenPush() async throws {
        let gitClient = RecordingGitClient()
        let viewModel = makeViewModel(gitClient: gitClient)
        let repo = makeRepo(state: .blockedDirty, error: "blocked")
        try await store.upsert(repo)
        await viewModel.refresh()

        let success = await viewModel.quickAddCommitPush(repo: repo, message: "feat: quick flow")
        let calls = await gitClient.recordedCalls()

        XCTAssertTrue(success)
        XCTAssertEqual(
            calls,
            [
                .stageAll,
                .commit(message: "feat: quick flow"),
                .push,
            ]
        )
    }

    func testEmptyCommitMessageBlocksCommitPaths() async throws {
        let gitClient = RecordingGitClient()
        let viewModel = makeViewModel(gitClient: gitClient)
        let repo = makeRepo()
        try await store.upsert(repo)
        await viewModel.refresh()

        let commitSuccess = await viewModel.commit(repo: repo, message: "   ")
        let quickFlowSuccess = await viewModel.quickAddCommitPush(repo: repo, message: " \n ")
        let calls = await gitClient.recordedCalls()

        XCTAssertFalse(commitSuccess)
        XCTAssertFalse(quickFlowSuccess)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(bannerCenter.banner?.text, RepoError.invalidCommitMessage.localizedDescription)
    }

    func testDiscardSuccessClearsBlockedState() async throws {
        let gitClient = RecordingGitClient()
        let viewModel = makeViewModel(gitClient: gitClient)
        let repo = makeRepo(state: .blockedDirty, error: "dirty working tree")
        try await store.upsert(repo)
        await viewModel.refresh()

        await viewModel.discardLocalChanges(repo: repo)
        let updated = try await store.repo(id: repo.id)
        let calls = await gitClient.recordedCalls()

        XCTAssertEqual(calls, [.discard])
        XCTAssertEqual(updated?.lastSyncState, .idle)
        XCTAssertNil(updated?.lastErrorMessage)
    }

    func testResetSuccessClearsBlockedState() async throws {
        let gitClient = RecordingGitClient()
        let viewModel = makeViewModel(gitClient: gitClient)
        let repo = makeRepo(state: .blockedDiverged, error: "diverged")
        try await store.upsert(repo)
        await viewModel.refresh()

        await viewModel.resetToRemote(repo: repo)
        let updated = try await store.repo(id: repo.id)
        let calls = await gitClient.recordedCalls()

        XCTAssertEqual(calls, [.resetToRemote])
        XCTAssertEqual(updated?.lastSyncState, .idle)
        XCTAssertNil(updated?.lastErrorMessage)
    }

    func testIdentityMustBeSavedBeforeCommitWhenGitClientRequiresIt() async throws {
        let gitClient = RecordingGitClient(requireIdentityBeforeCommit: true)
        let viewModel = makeViewModel(gitClient: gitClient)
        let repo = makeRepo()
        try await store.upsert(repo)
        await viewModel.refresh()

        let firstCommitSuccess = await viewModel.commit(repo: repo, message: "first attempt")
        let saveSuccess = await viewModel.saveCommitIdentity(
            repo: repo,
            name: "Taylor Test",
            email: "taylor@example.com"
        )
        let secondCommitSuccess = await viewModel.commit(repo: repo, message: "second attempt")
        let calls = await gitClient.recordedCalls()

        XCTAssertFalse(firstCommitSuccess)
        XCTAssertTrue(saveSuccess)
        XCTAssertTrue(secondCommitSuccess)
        XCTAssertEqual(
            calls,
            [
                .commit(message: "first attempt"),
                .saveIdentity(name: "Taylor Test", email: "taylor@example.com"),
                .commit(message: "second attempt"),
            ]
        )
    }

    private func makeViewModel(gitClient: GitClient) -> RepoListViewModel {
        RepoListViewModel(
            repoStore: store,
            gitClient: gitClient,
            logger: AppLogger(),
            keyManager: NoopKeyManager(),
            bannerCenter: bannerCenter
        )
    }

    private func makeRepo(
        state: RepoSyncState = .idle,
        error: String? = nil
    ) -> RepoRecord {
        RepoRecord(
            id: RepoID(),
            displayName: "Repo",
            remoteURL: "ssh://git@github.com:22/owner/repo.git",
            localPath: "/tmp/repo-\(UUID().uuidString)",
            trackedBranch: "main",
            autoSyncEnabled: true,
            lastSyncAt: nil,
            lastSyncState: state,
            lastErrorMessage: error
        )
    }
}
