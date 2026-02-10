import Core
import Foundation
import SwiftData

@MainActor
public final class RepoStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func listRepos() throws -> [RepoRecord] {
        var descriptor = FetchDescriptor<RepoEntity>(
            sortBy: [SortDescriptor(\.displayName, order: .forward)]
        )
        descriptor.fetchLimit = 500
        return try context.fetch(descriptor).map { $0.toRepoRecord() }
    }

    public func repo(id: RepoID) throws -> RepoRecord? {
        let key = id.rawValue
        let predicate = #Predicate<RepoEntity> { entity in
            entity.id == key
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.toRepoRecord()
    }

    public func upsert(_ record: RepoRecord) throws {
        if let existing = try fetchRepoEntity(id: record.id.rawValue) {
            existing.apply(record)
        } else {
            context.insert(RepoEntity(record: record))
        }
        try context.save()
    }

    public func delete(repoID: RepoID) throws {
        guard let entity = try fetchRepoEntity(id: repoID.rawValue) else {
            return
        }
        context.delete(entity)
        try context.save()
    }

    public func setSyncResult(repoID: RepoID, result: SyncResult) throws {
        guard let entity = try fetchRepoEntity(id: repoID.rawValue) else {
            return
        }
        entity.lastSyncAt = result.completedAt
        entity.lastSyncStateRaw = result.state.rawValue
        entity.lastErrorMessage = result.message
        try context.save()
    }

    public func fingerprint(host: String, port: Int, algorithm: String) throws -> HostFingerprintRecord? {
        let lookup = HostFingerprintEntity.makeLookupKey(host: host, port: port, algorithm: algorithm)
        let predicate = #Predicate<HostFingerprintEntity> { entity in
            entity.lookupKey == lookup
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.toRecord()
    }

    public func saveFingerprint(_ record: HostFingerprintRecord) throws {
        let lookup = HostFingerprintEntity.makeLookupKey(host: record.host, port: record.port, algorithm: record.algorithm)
        let predicate = #Predicate<HostFingerprintEntity> { entity in
            entity.lookupKey == lookup
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.fingerprintSHA256 = record.fingerprintSHA256
            existing.acceptedAt = record.acceptedAt
        } else {
            context.insert(
                HostFingerprintEntity(
                    host: record.host,
                    port: record.port,
                    algorithm: record.algorithm,
                    fingerprintSHA256: record.fingerprintSHA256,
                    acceptedAt: record.acceptedAt
                )
            )
        }
        try context.save()
    }

    public func listFingerprints() throws -> [HostFingerprintRecord] {
        let descriptor = FetchDescriptor<HostFingerprintEntity>(
            sortBy: [
                SortDescriptor(\.host, order: .forward),
                SortDescriptor(\.port, order: .forward),
                SortDescriptor(\.algorithm, order: .forward)
            ]
        )
        return try context.fetch(descriptor).map { $0.toRecord() }
    }

    public func deleteFingerprint(host: String, port: Int, algorithm: String) throws {
        let lookup = HostFingerprintEntity.makeLookupKey(host: host, port: port, algorithm: algorithm)
        let predicate = #Predicate<HostFingerprintEntity> { entity in
            entity.lookupKey == lookup
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let existing = try context.fetch(descriptor).first else {
            return
        }
        context.delete(existing)
        try context.save()
    }

    public func listKeys(host: String? = nil) throws -> [SSHKeyRecord] {
        let descriptor: FetchDescriptor<SSHKeyEntity>
        if let host {
            let lowerHost = host.lowercased()
            let predicate = #Predicate<SSHKeyEntity> { entity in
                entity.hostLookup == lowerHost
            }
            descriptor = FetchDescriptor(predicate: predicate)
        } else {
            descriptor = FetchDescriptor()
        }

        return try context.fetch(descriptor).map { $0.toRecord() }
    }

    public func saveKey(_ key: SSHKeyRecord, isHostDefault: Bool) throws {
        if isHostDefault {
            let hostLower = key.host.lowercased()
            let predicate = #Predicate<SSHKeyEntity> { entity in
                entity.hostLookup == hostLower
            }
            let existing = try context.fetch(FetchDescriptor(predicate: predicate))
            for entry in existing {
                entry.isHostDefault = entry.id == key.id
            }
        }

        if let existing = try fetchKeyEntity(id: key.id) {
            existing.host = key.host
            existing.hostLookup = key.host.lowercased()
            existing.label = key.label
            existing.algorithm = key.algorithm
            existing.keySource = key.keySource
            existing.publicKeyOpenSSH = key.publicKeyOpenSSH
            existing.keychainPrivateRef = key.keychainPrivateRef
            existing.keychainPassphraseRef = key.keychainPassphraseRef
            existing.isHostDefault = isHostDefault
        } else {
            context.insert(
                SSHKeyEntity(
                    id: key.id,
                    host: key.host,
                    label: key.label,
                    algorithm: key.algorithm,
                    keySource: key.keySource,
                    publicKeyOpenSSH: key.publicKeyOpenSSH,
                    keychainPrivateRef: key.keychainPrivateRef,
                    keychainPassphraseRef: key.keychainPassphraseRef,
                    isHostDefault: isHostDefault
                )
            )
        }

        try context.save()
    }

    public func setDefaultKey(host: String, keyID: UUID) throws {
        let hostLower = host.lowercased()
        let predicate = #Predicate<SSHKeyEntity> { entity in
            entity.hostLookup == hostLower
        }
        let entries = try context.fetch(FetchDescriptor(predicate: predicate))
        guard entries.contains(where: { $0.id == keyID }) else {
            throw RepoError.keyNotFound
        }

        for entry in entries {
            entry.isHostDefault = entry.id == keyID
        }
        try context.save()
    }

    public func deleteKey(id: UUID) throws -> SSHKeyRecord? {
        guard let entity = try fetchKeyEntity(id: id) else {
            return nil
        }

        let removed = entity.toRecord()
        let hostLookup = entity.hostLookup
        let removedWasDefault = entity.isHostDefault
        context.delete(entity)

        if removedWasDefault {
            let predicate = #Predicate<SSHKeyEntity> { entry in
                entry.hostLookup == hostLookup
            }
            let remaining = try context.fetch(FetchDescriptor(predicate: predicate))
                .sorted { lhs, rhs in
                    lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
            remaining.first?.isHostDefault = true
        }

        try context.save()
        return removed
    }

    public func defaultKey(host: String) throws -> SSHKeyRecord? {
        let lowerHost = host.lowercased()
        let predicate = #Predicate<SSHKeyEntity> { entity in
            entity.hostLookup == lowerHost && entity.isHostDefault
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.toRecord()
    }

    private func fetchRepoEntity(id: UUID) throws -> RepoEntity? {
        let predicate = #Predicate<RepoEntity> { entity in
            entity.id == id
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchKeyEntity(id: UUID) throws -> SSHKeyEntity? {
        let predicate = #Predicate<SSHKeyEntity> { entity in
            entity.id == id
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

private extension RepoEntity {
    convenience init(record: RepoRecord) {
        self.init(
            id: record.id.rawValue,
            displayName: record.displayName,
            remoteURL: record.remoteURL,
            localPath: record.localPath,
            securityScopedBookmark: record.securityScopedBookmark,
            trackedBranch: record.trackedBranch,
            sshKeyOverrideID: record.sshKeyOverrideID,
            autoSyncEnabled: record.autoSyncEnabled,
            lastSyncAt: record.lastSyncAt,
            lastSyncStateRaw: record.lastSyncState.rawValue,
            lastErrorMessage: record.lastErrorMessage
        )
    }

    func toRepoRecord() -> RepoRecord {
        RepoRecord(
            id: RepoID(rawValue: id),
            displayName: displayName,
            remoteURL: remoteURL,
            localPath: localPath,
            securityScopedBookmark: securityScopedBookmark,
            trackedBranch: trackedBranch,
            sshKeyOverrideID: sshKeyOverrideID,
            autoSyncEnabled: autoSyncEnabled,
            lastSyncAt: lastSyncAt,
            lastSyncState: RepoSyncState(rawValue: lastSyncStateRaw) ?? .idle,
            lastErrorMessage: lastErrorMessage
        )
    }

    func apply(_ record: RepoRecord) {
        displayName = record.displayName
        remoteURL = record.remoteURL
        localPath = record.localPath
        securityScopedBookmark = record.securityScopedBookmark
        trackedBranch = record.trackedBranch
        sshKeyOverrideID = record.sshKeyOverrideID
        autoSyncEnabled = record.autoSyncEnabled
        lastSyncAt = record.lastSyncAt
        lastSyncStateRaw = record.lastSyncState.rawValue
        lastErrorMessage = record.lastErrorMessage
    }
}

private extension HostFingerprintEntity {
    func toRecord() -> HostFingerprintRecord {
        HostFingerprintRecord(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprintSHA256: fingerprintSHA256,
            acceptedAt: acceptedAt
        )
    }
}

private extension SSHKeyEntity {
    func toRecord() -> SSHKeyRecord {
        SSHKeyRecord(
            id: id,
            host: host,
            label: label,
            algorithm: algorithm,
            keySource: keySource,
            publicKeyOpenSSH: publicKeyOpenSSH,
            keychainPrivateRef: keychainPrivateRef,
            keychainPassphraseRef: keychainPassphraseRef
        )
    }
}
