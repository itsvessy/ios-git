import Core
import Foundation
import GitEngine
import SwiftGitX
import XCTest

private actor TrustAllEvaluator: HostTrustEvaluator {
    func evaluate(host: String, port: Int, presentedFingerprint: String, algorithm: String) async throws -> TrustDecision {
        .trustAndPin
    }
}

private actor RejectTrustEvaluator: HostTrustEvaluator {
    func evaluate(host: String, port: Int, presentedFingerprint: String, algorithm: String) async throws -> TrustDecision {
        throw RepoError.hostTrustRejected
    }
}

private struct StaticCredentialProvider: SSHCredentialProvider {
    func credential(for host: String, username: String?) async throws -> SSHCredentialMaterial {
        SSHCredentialMaterial(
            username: username ?? "git",
            privateKey: Data(repeating: 7, count: 32),
            passphrase: nil
        )
    }
}

final class FileSystemGitClientTests: XCTestCase {
    func testProbeRemoteNormalizesSSHURL() async throws {
        let client = FileSystemGitClient(trustEvaluator: TrustAllEvaluator())

        let result = try await client.probeRemote("git@github.com:owner/repo.git")

        XCTAssertEqual(result.host, "github.com")
        XCTAssertEqual(result.port, 22)
        XCTAssertEqual(result.normalizedURL, "ssh://git@github.com:22/owner/repo.git")
    }

    func testPrepareRemoteNormalizesSSHURL() async throws {
        let client = FileSystemGitClient(trustEvaluator: TrustAllEvaluator())

        let result = try await client.prepareRemote("git@github.com:owner/repo.git")

        XCTAssertEqual(result.host, "github.com")
        XCTAssertEqual(result.port, 22)
        XCTAssertEqual(result.normalizedURL, "ssh://git@github.com:22/owner/repo.git")
    }

    func testPrepareRemotePropagatesTrustRejection() async {
        let client = FileSystemGitClient(trustEvaluator: RejectTrustEvaluator())

        do {
            _ = try await client.prepareRemote("git@github.com:owner/repo.git")
            XCTFail("Expected hostTrustRejected")
        } catch let error as RepoError {
            guard case .hostTrustRejected = error else {
                return XCTFail("Unexpected RepoError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCloneFailsWithoutCredentials() async {
        let client = FileSystemGitClient(trustEvaluator: TrustAllEvaluator())
        let tempRoot = try! makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        do {
            _ = try await client.clone(
                CloneRequest(
                    displayName: "Repo",
                    remoteURL: "git@github.com:owner/repo.git",
                    targetDirectory: tempRoot,
                    trackedBranch: "main",
                    autoSyncEnabled: true
                )
            )
            XCTFail("Expected keyNotFound")
        } catch let error as RepoError {
            guard case .keyNotFound = error else {
                return XCTFail("Unexpected RepoError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSyncReturnsFailedWhenLocalPathIsMissing() async throws {
        let client = FileSystemGitClient(trustEvaluator: TrustAllEvaluator())
        let repo = RepoRecord(
            id: RepoID(),
            displayName: "Missing",
            remoteURL: "ssh://git@github.com:22/owner/repo.git",
            localPath: "/tmp/path-that-does-not-exist-\(UUID().uuidString)",
            trackedBranch: "main",
            autoSyncEnabled: true
        )

        let result = try await client.sync(repo, trigger: .manual)
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.message, "Repository directory missing.")
    }

    func testStageSelectedFilesStagesOnlyRequestedPaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("work", isDirectory: true)
        let repository = try createRepository(at: repoURL)
        try seedInitialCommit(
            repository: repository,
            files: [
                "selected.txt": "selected initial\n",
                "other.txt": "other initial\n",
            ]
        )

        try writeFile("selected changed\n", at: "selected.txt", in: repoURL)
        try writeFile("other changed\n", at: "other.txt", in: repoURL)

        let client = makeClient()
        let repo = try makeRepoRecord(localPath: repoURL.path, repository: repository)
        try await client.stage(repo, paths: ["selected.txt"])

        let changes = try await client.listLocalChanges(repo)
        let map = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })

        XCTAssertEqual(map["selected.txt"]?.stageState, .staged)
        XCTAssertEqual(map["other.txt"]?.stageState, .unstaged)
    }

    func testStageAllStagesAllChangedPaths() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("work", isDirectory: true)
        let repository = try createRepository(at: repoURL)
        try seedInitialCommit(
            repository: repository,
            files: [
                "tracked.txt": "tracked\n",
                "removed.txt": "remove me\n",
            ]
        )

        try writeFile("tracked changed\n", at: "tracked.txt", in: repoURL)
        try FileManager.default.removeItem(at: repoURL.appendingPathComponent("removed.txt"))
        try writeFile("new file\n", at: "added.txt", in: repoURL)

        let client = makeClient()
        let repo = try makeRepoRecord(localPath: repoURL.path, repository: repository)
        try await client.stageAll(repo)

        let changes = try await client.listLocalChanges(repo)
        let expectedPaths: Set<String> = ["tracked.txt", "removed.txt", "added.txt"]

        XCTAssertEqual(Set(changes.map(\.path)), expectedPaths)
        XCTAssertTrue(changes.allSatisfy { $0.stageState == .staged }, "Expected all changes staged: \(changes)")
    }

    func testCommitFailsWithoutIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("work", isDirectory: true)
        let repository = try createRepository(at: repoURL)
        try seedInitialCommit(repository: repository, files: ["file.txt": "hello\n"])
        try repository.config.set("user.name", to: "")
        try repository.config.set("user.email", to: "")

        try writeFile("hello again\n", at: "file.txt", in: repoURL)

        let client = makeClient()
        let repo = try makeRepoRecord(localPath: repoURL.path, repository: repository)
        try await client.stageAll(repo)

        do {
            _ = try await client.commit(repo, message: "update")
            XCTFail("Expected commitIdentityMissing")
        } catch let error as RepoError {
            guard case .commitIdentityMissing = error else {
                return XCTFail("Unexpected RepoError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommitIdentitySaveLoadRoundtrip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("work", isDirectory: true)
        let repository = try createRepository(at: repoURL)

        let client = makeClient()
        let repo = try makeRepoRecord(localPath: repoURL.path, repository: repository)

        let initial = try await client.loadCommitIdentity(repo)
        XCTAssertNil(initial)

        let identity = RepoCommitIdentity(name: "Taylor Test", email: "taylor@example.com")
        try await client.saveCommitIdentity(identity, for: repo)
        let loaded = try await client.loadCommitIdentity(repo)

        XCTAssertEqual(loaded, identity)
    }

    func testCommitWithIdentityCreatesNewCommit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("work", isDirectory: true)
        let repository = try createRepository(at: repoURL)
        try seedInitialCommit(repository: repository, files: ["tracked.txt": "initial\n"])

        let client = makeClient()
        let repo = try makeRepoRecord(localPath: repoURL.path, repository: repository)
        try await client.saveCommitIdentity(
            RepoCommitIdentity(name: "Taylor Test", email: "taylor@example.com"),
            for: repo
        )

        let before = try headCommitID(in: repository)
        try writeFile("changed\n", at: "tracked.txt", in: repoURL)
        try await client.stageAll(repo)
        let result = try await client.commit(repo, message: "  update tracked file  ")
        let after = try headCommitID(in: repository)

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, result.commitID)
        XCTAssertEqual(result.message, "update tracked file")
    }

    func testPushWorksAgainstLocalBareRemote() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bareURL = root.appendingPathComponent("remote.git", isDirectory: true)
        let bareRepository = try Repository.create(at: bareURL, isBare: true)

        let localURL = root.appendingPathComponent("work", isDirectory: true)
        let localRepository = try createRepository(at: localURL)
        try seedInitialCommit(repository: localRepository, files: ["tracked.txt": "initial\n"])
        let remote = try localRepository.remote.add(named: "origin", at: bareURL)
        try await localRepository.push(remote: remote)

        let trackedBranch = try currentBranchName(in: localRepository)
        let client = makeClient()
        let repo = makeRepoRecord(localPath: localURL.path, trackedBranch: trackedBranch)

        try await client.saveCommitIdentity(
            RepoCommitIdentity(name: "Taylor Test", email: "taylor@example.com"),
            for: repo
        )
        try writeFile("second\n", at: "tracked.txt", in: localURL)
        try await client.stageAll(repo)
        _ = try await client.commit(repo, message: "second")
        let pushResult = try await client.push(repo)

        let localHead = try headCommitID(in: localRepository)
        let remoteHead = try branchCommitID(in: bareRepository, branch: trackedBranch, type: .local)

        XCTAssertEqual(localHead, remoteHead)
        XCTAssertEqual(pushResult.remoteName, "origin")
        XCTAssertEqual(pushResult.branchName, trackedBranch)
    }

    func testDiscardRemovesTrackedStagedAndUntrackedChanges() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("work", isDirectory: true)
        let repository = try createRepository(at: repoURL)
        try seedInitialCommit(repository: repository, files: ["tracked.txt": "base\n"])

        let client = makeClient()
        let repo = try makeRepoRecord(localPath: repoURL.path, repository: repository)

        try writeFile("staged\n", at: "tracked.txt", in: repoURL)
        try await client.stageAll(repo)
        try writeFile("staged\nunstaged\n", at: "tracked.txt", in: repoURL)
        try writeFile("temp\n", at: "temp.txt", in: repoURL)
        try writeFile("nested\n", at: "scratch/data.txt", in: repoURL)

        try await client.discardLocalChanges(repo)

        let changes = try await client.listLocalChanges(repo)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(try readFile(at: "tracked.txt", in: repoURL), "base\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("temp.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("scratch/data.txt").path))
    }

    func testResetToRemoteHardResetsLocalDivergence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bareURL = root.appendingPathComponent("remote.git", isDirectory: true)
        let bareRepository = try Repository.create(at: bareURL, isBare: true)

        let localURL = root.appendingPathComponent("local", isDirectory: true)
        let localRepository = try createRepository(at: localURL)
        try seedInitialCommit(repository: localRepository, files: ["tracked.txt": "initial\n"])
        let remote = try localRepository.remote.add(named: "origin", at: bareURL)
        try await localRepository.push(remote: remote)

        let trackedBranch = try currentBranchName(in: localRepository)

        let peerURL = root.appendingPathComponent("peer", isDirectory: true)
        let peerRepository = try await Repository.clone(from: bareURL, to: peerURL)
        try peerRepository.config.set("user.name", to: "Peer User")
        try peerRepository.config.set("user.email", to: "peer@example.com")
        try writeFile("remote update\n", at: "tracked.txt", in: peerURL)
        try peerRepository.add(paths: ["tracked.txt"])
        _ = try peerRepository.commit(message: "remote change")
        try await peerRepository.push(remote: peerRepository.remote["origin"])

        let remoteHeadBeforeReset = try branchCommitID(in: bareRepository, branch: trackedBranch, type: .local)

        try writeFile("local divergence\n", at: "tracked.txt", in: localURL)
        try localRepository.add(paths: ["tracked.txt"])
        _ = try localRepository.commit(message: "local change")
        let localHeadBeforeReset = try headCommitID(in: localRepository)
        XCTAssertNotEqual(localHeadBeforeReset, remoteHeadBeforeReset)

        let client = makeClient()
        let repo = makeRepoRecord(localPath: localURL.path, trackedBranch: trackedBranch)
        let result = try await client.resetToRemote(repo)

        let localHeadAfterReset = try headCommitID(in: localRepository)
        let changesAfterReset = try await client.listLocalChanges(repo)

        XCTAssertEqual(result.state, .success)
        XCTAssertEqual(localHeadAfterReset, remoteHeadBeforeReset)
        XCTAssertNotEqual(localHeadAfterReset, localHeadBeforeReset)
        XCTAssertTrue(changesAfterReset.isEmpty)
    }

    private func makeClient() -> FileSystemGitClient {
        FileSystemGitClient(
            trustEvaluator: TrustAllEvaluator(),
            credentialProvider: StaticCredentialProvider()
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitphone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createRepository(at url: URL) throws -> Repository {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try Repository.create(at: url)
    }

    private func makeRepoRecord(localPath: String, trackedBranch: String) -> RepoRecord {
        RepoRecord(
            id: RepoID(),
            displayName: "Test Repo",
            remoteURL: "ssh://git@localhost:22/owner/repo.git",
            localPath: localPath,
            trackedBranch: trackedBranch,
            autoSyncEnabled: true
        )
    }

    private func makeRepoRecord(localPath: String, repository: Repository) throws -> RepoRecord {
        let trackedBranch: String
        if let current = try? currentBranchName(in: repository) {
            trackedBranch = current
        } else {
            trackedBranch = (try? repository.config.defaultBranchName) ?? "main"
        }
        return makeRepoRecord(localPath: localPath, trackedBranch: trackedBranch)
    }

    private func currentBranchName(in repository: Repository) throws -> String {
        try repository.branch.current.name
    }

    private func headCommitID(in repository: Repository) throws -> String {
        let current = try repository.branch.current
        guard let commit = current.target as? Commit else {
            throw RepoError.ioFailure("Current branch does not point to a commit.")
        }
        return commit.id.hex
    }

    private func branchCommitID(in repository: Repository, branch: String, type: BranchType) throws -> String {
        guard let branch = repository.branch[branch, type: type],
              let commit = branch.target as? Commit else {
            throw RepoError.ioFailure("Could not resolve branch tip for \(branch).")
        }
        return commit.id.hex
    }

    private func seedInitialCommit(
        repository: Repository,
        files: [String: String]
    ) throws {
        let workingDirectory = try repository.workingDirectory
        for (path, contents) in files {
            try writeFile(contents, at: path, in: workingDirectory)
        }
        try repository.config.set("user.name", to: "Test User")
        try repository.config.set("user.email", to: "test@example.com")
        try repository.add(paths: Array(files.keys))
        _ = try repository.commit(message: "initial")
    }

    private func writeFile(_ contents: String, at relativePath: String, in root: URL) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL, options: .atomic)
    }

    private func readFile(at relativePath: String, in root: URL) throws -> String {
        let fileURL = root.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
