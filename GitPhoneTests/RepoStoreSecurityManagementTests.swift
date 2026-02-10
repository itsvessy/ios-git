import Core
import Foundation
import Storage
import SwiftData
import XCTest

@MainActor
final class RepoStoreSecurityManagementTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!

    override func setUpWithError() throws {
        let schema = Schema(StorageSchema.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        store = RepoStore(container: container)
    }

    override func tearDownWithError() throws {
        container = nil
        store = nil
    }

    func testListAndDeleteFingerprints() async throws {
        try await store.saveFingerprint(
            HostFingerprintRecord(
                host: "github.com",
                port: 22,
                algorithm: "ed25519",
                fingerprintSHA256: "AAA",
                acceptedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try await store.saveFingerprint(
            HostFingerprintRecord(
                host: "gitlab.com",
                port: 22,
                algorithm: "rsa",
                fingerprintSHA256: "BBB",
                acceptedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let all = try await store.listFingerprints()
        XCTAssertEqual(all.count, 2)

        try await store.deleteFingerprint(host: "github.com", port: 22, algorithm: "ed25519")

        let afterDelete = try await store.listFingerprints()
        XCTAssertEqual(afterDelete.count, 1)
        XCTAssertEqual(afterDelete.first?.host, "gitlab.com")
    }

    func testSetDefaultKeyUpdatesHostDefault() async throws {
        let first = makeKey(host: "github.com", label: "Key A")
        let second = makeKey(host: "github.com", label: "Key B")

        try await store.saveKey(first, isHostDefault: true)
        try await store.saveKey(second, isHostDefault: false)

        try await store.setDefaultKey(host: "github.com", keyID: second.id)

        let defaultKey = try await store.defaultKey(host: "github.com")
        XCTAssertEqual(defaultKey?.id, second.id)
    }

    func testDeleteKeyPromotesNextDefaultForHost() async throws {
        let first = makeKey(host: "github.com", label: "Key A")
        let second = makeKey(host: "github.com", label: "Key B")

        try await store.saveKey(first, isHostDefault: true)
        try await store.saveKey(second, isHostDefault: false)

        let removed = try await store.deleteKey(id: first.id)
        XCTAssertEqual(removed?.id, first.id)

        let defaultAfterDelete = try await store.defaultKey(host: "github.com")
        XCTAssertEqual(defaultAfterDelete?.id, second.id)

        _ = try await store.deleteKey(id: second.id)
        let defaultAfterRemovingAll = try await store.defaultKey(host: "github.com")
        XCTAssertNil(defaultAfterRemovingAll)
    }

    private func makeKey(host: String, label: String) -> SSHKeyRecord {
        SSHKeyRecord(
            id: UUID(),
            host: host,
            label: label,
            algorithm: "ed25519",
            keySource: "generated",
            publicKeyOpenSSH: "ssh-ed25519 AAA",
            keychainPrivateRef: "private.\(UUID().uuidString)",
            keychainPassphraseRef: nil
        )
    }
}
