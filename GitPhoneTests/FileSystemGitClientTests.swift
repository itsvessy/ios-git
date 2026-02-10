import Core
import Foundation
import GitEngine
import XCTest

private actor TrustAllEvaluator: HostTrustEvaluator {
    func evaluate(host: String, port: Int, presentedFingerprint: String, algorithm: String) async throws -> TrustDecision {
        .trustAndPin
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

    func testCloneFailsWithoutCredentials() async {
        let client = FileSystemGitClient(trustEvaluator: TrustAllEvaluator())
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
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
}
