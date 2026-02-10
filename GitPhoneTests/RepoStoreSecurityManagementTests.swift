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
        store = RepoStore(context: container.mainContext)
    }

    override func tearDownWithError() throws {
        container = nil
        store = nil
    }

    func testListAndDeleteFingerprints() throws {
        try store.saveFingerprint(
            HostFingerprintRecord(
                host: "github.com",
                port: 22,
                algorithm: "ed25519",
                fingerprintSHA256: "AAA",
                acceptedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try store.saveFingerprint(
            HostFingerprintRecord(
                host: "gitlab.com",
                port: 22,
                algorithm: "rsa",
                fingerprintSHA256: "BBB",
                acceptedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let all = try store.listFingerprints()
        XCTAssertEqual(all.count, 2)

        try store.deleteFingerprint(host: "github.com", port: 22, algorithm: "ed25519")

        let afterDelete = try store.listFingerprints()
        XCTAssertEqual(afterDelete.count, 1)
        XCTAssertEqual(afterDelete.first?.host, "gitlab.com")
    }

    func testSetDefaultKeyUpdatesHostDefault() throws {
        let first = makeKey(host: "github.com", label: "Key A")
        let second = makeKey(host: "github.com", label: "Key B")

        try store.saveKey(first, isHostDefault: true)
        try store.saveKey(second, isHostDefault: false)

        try store.setDefaultKey(host: "github.com", keyID: second.id)

        let defaultKey = try store.defaultKey(host: "github.com")
        XCTAssertEqual(defaultKey?.id, second.id)
    }

    func testDeleteKeyPromotesNextDefaultForHost() throws {
        let first = makeKey(host: "github.com", label: "Key A")
        let second = makeKey(host: "github.com", label: "Key B")

        try store.saveKey(first, isHostDefault: true)
        try store.saveKey(second, isHostDefault: false)

        let removed = try store.deleteKey(id: first.id)
        XCTAssertEqual(removed?.id, first.id)

        let defaultAfterDelete = try store.defaultKey(host: "github.com")
        XCTAssertEqual(defaultAfterDelete?.id, second.id)

        _ = try store.deleteKey(id: second.id)
        let defaultAfterRemovingAll = try store.defaultKey(host: "github.com")
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
