import Core
import Foundation
import SecurityEngine
import Storage
import SwiftData
import XCTest
@testable import GitPhone

private struct StubGitClient: GitClient {
    let prepareResult: Result<RemoteProbeResult, RepoError>

    func prepareRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        try prepareResult.get()
    }

    func clone(_ request: CloneRequest) async throws -> RepoRecord {
        throw RepoError.ioFailure("not used in tests")
    }

    func sync(_ repo: RepoRecord, trigger: SyncTrigger) async throws -> SyncResult {
        SyncResult(state: .success, message: "ok")
    }

    func probeRemote(_ remoteURL: String) async throws -> RemoteProbeResult {
        try prepareResult.get()
    }

    func listLocalChanges(_ repo: RepoRecord) async throws -> [RepoLocalChange] {
        []
    }

    func stage(_ repo: RepoRecord, paths: [String]) async throws {}

    func stageAll(_ repo: RepoRecord) async throws {}

    func loadCommitIdentity(_ repo: RepoRecord) async throws -> RepoCommitIdentity? {
        nil
    }

    func saveCommitIdentity(_ identity: RepoCommitIdentity, for repo: RepoRecord) async throws {}

    func commit(_ repo: RepoRecord, message: String) async throws -> RepoCommitResult {
        RepoCommitResult(commitID: "deadbeef", message: message)
    }

    func push(_ repo: RepoRecord) async throws -> RepoPushResult {
        RepoPushResult(remoteName: "origin", branchName: repo.trackedBranch)
    }

    func discardLocalChanges(_ repo: RepoRecord) async throws {}

    func resetToRemote(_ repo: RepoRecord) async throws -> SyncResult {
        SyncResult(state: .success, message: "ok")
    }
}

private struct StubKeyManager: SSHKeyManaging {
    let generatedPublicKey: String

    func generateKey(
        host: String,
        label: String,
        preferredAlgorithm: SSHKeyAlgorithm,
        passphrase: String?
    ) throws -> GeneratedSSHKey {
        let keyID = UUID()
        let key = SSHKeyRecord(
            id: keyID,
            host: host,
            label: label,
            algorithm: preferredAlgorithm.rawValue,
            keySource: "generated",
            publicKeyOpenSSH: generatedPublicKey,
            keychainPrivateRef: "ssh.private.\(keyID.uuidString)",
            keychainPassphraseRef: passphrase == nil ? nil : "ssh.passphrase.\(keyID.uuidString)"
        )
        return GeneratedSSHKey(record: key, privateKeyData: Data("private".utf8))
    }

    func loadPrivateKey(reference: String, prompt: String) throws -> Data {
        throw RepoError.keychainFailure("not used in tests")
    }

    func loadPassphrase(reference: String, prompt: String) throws -> String {
        throw RepoError.keychainFailure("not used in tests")
    }

    func deleteMaterial(privateRef: String, passphraseRef: String?) throws {}
}

@MainActor
final class RepoListSSHPreparationTests: XCTestCase {
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

    func testPrepareSSHReusesExistingDefaultKey() async throws {
        let existing = makeKey(host: "github.com", label: "Existing")
        try await store.saveKey(existing, isHostDefault: true)

        let viewModel = makeViewModel(
            gitClient: StubGitClient(
                prepareResult: .success(
                    RemoteProbeResult(
                        host: "github.com",
                        port: 22,
                        normalizedURL: "ssh://git@github.com:22/owner/repo.git"
                    )
                )
            )
        )

        let preparation = try await viewModel.prepareSSHForAddRepo(
            remoteURL: "git@github.com:owner/repo.git",
            passphrase: nil
        )

        XCTAssertFalse(preparation.didGenerateKey)
        XCTAssertEqual(preparation.key.id, existing.id)
        XCTAssertEqual(preparation.normalizedRemoteURL, "ssh://git@github.com:22/owner/repo.git")
        let keyCount = try await store.listKeys(host: "github.com").count
        XCTAssertEqual(keyCount, 1)
    }

    func testPrepareSSHGeneratesKeyWhenMissing() async throws {
        let viewModel = makeViewModel(
            gitClient: StubGitClient(
                prepareResult: .success(
                    RemoteProbeResult(
                        host: "github.com",
                        port: 22,
                        normalizedURL: "ssh://git@github.com:22/owner/repo.git"
                    )
                )
            )
        )

        let preparation = try await viewModel.prepareSSHForAddRepo(
            remoteURL: "git@github.com:owner/repo.git",
            passphrase: nil
        )

        XCTAssertTrue(preparation.didGenerateKey)
        XCTAssertEqual(preparation.key.host, "github.com")
        XCTAssertEqual(preparation.key.keySource, "generated")
        let defaultKeyID = try await store.defaultKey(host: "github.com")?.id
        XCTAssertEqual(defaultKeyID, preparation.key.id)
        XCTAssertEqual(viewModel.sshKeys.map(\.id), [preparation.key.id])
    }

    func testPrepareSSHPropagatesTrustFailure() async {
        let viewModel = makeViewModel(
            gitClient: StubGitClient(prepareResult: .failure(.hostTrustRejected))
        )

        do {
            _ = try await viewModel.prepareSSHForAddRepo(
                remoteURL: "git@github.com:owner/repo.git",
                passphrase: nil
            )
            XCTFail("Expected hostTrustRejected")
        } catch let error as RepoError {
            guard case .hostTrustRejected = error else {
                return XCTFail("Unexpected RepoError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let areKeysEmpty = (try? await store.listKeys().isEmpty) == true
        XCTAssertTrue(areKeysEmpty)
    }

    func testPrepareSSHDoesNotCreateRepoEntry() async throws {
        let viewModel = makeViewModel(
            gitClient: StubGitClient(
                prepareResult: .success(
                    RemoteProbeResult(
                        host: "github.com",
                        port: 22,
                        normalizedURL: "ssh://git@github.com:22/owner/repo.git"
                    )
                )
            )
        )

        _ = try await viewModel.prepareSSHForAddRepo(
            remoteURL: "git@github.com:owner/repo.git",
            passphrase: nil
        )

        let reposAreEmpty = try await store.listRepos().isEmpty
        XCTAssertTrue(reposAreEmpty)
    }

    private func makeViewModel(gitClient: GitClient) -> RepoListViewModel {
        RepoListViewModel(
            repoStore: store,
            gitClient: gitClient,
            logger: AppLogger(),
            keyManager: StubKeyManager(generatedPublicKey: "ssh-ed25519 AAAA-test"),
            bannerCenter: AppBannerCenter()
        )
    }

    private func makeKey(host: String, label: String) -> SSHKeyRecord {
        SSHKeyRecord(
            id: UUID(),
            host: host,
            label: label,
            algorithm: "ed25519",
            keySource: "generated",
            publicKeyOpenSSH: "ssh-ed25519 AAAA-existing",
            keychainPrivateRef: "private.\(UUID().uuidString)",
            keychainPassphraseRef: nil
        )
    }
}
