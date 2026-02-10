import Foundation
import SwiftData

@Model
public final class RepoEntity {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var remoteURL: String
    public var localPath: String
    public var securityScopedBookmark: Data?
    public var trackedBranch: String
    public var sshKeyOverrideID: UUID?
    public var autoSyncEnabled: Bool
    public var lastSyncAt: Date?
    public var lastSyncStateRaw: String
    public var lastErrorMessage: String?

    public init(
        id: UUID,
        displayName: String,
        remoteURL: String,
        localPath: String,
        securityScopedBookmark: Data?,
        trackedBranch: String,
        sshKeyOverrideID: UUID?,
        autoSyncEnabled: Bool,
        lastSyncAt: Date?,
        lastSyncStateRaw: String,
        lastErrorMessage: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.remoteURL = remoteURL
        self.localPath = localPath
        self.securityScopedBookmark = securityScopedBookmark
        self.trackedBranch = trackedBranch
        self.sshKeyOverrideID = sshKeyOverrideID
        self.autoSyncEnabled = autoSyncEnabled
        self.lastSyncAt = lastSyncAt
        self.lastSyncStateRaw = lastSyncStateRaw
        self.lastErrorMessage = lastErrorMessage
    }
}

@Model
public final class HostFingerprintEntity {
    @Attribute(.unique) public var lookupKey: String
    public var host: String
    public var port: Int
    public var algorithm: String
    public var fingerprintSHA256: String
    public var acceptedAt: Date

    public init(host: String, port: Int, algorithm: String, fingerprintSHA256: String, acceptedAt: Date) {
        self.host = host
        self.port = port
        self.algorithm = algorithm
        self.fingerprintSHA256 = fingerprintSHA256
        self.acceptedAt = acceptedAt
        self.lookupKey = Self.makeLookupKey(host: host, port: port, algorithm: algorithm)
    }

    public static func makeLookupKey(host: String, port: Int, algorithm: String) -> String {
        "\(host.lowercased()):\(port):\(algorithm.lowercased())"
    }
}

@Model
public final class SSHKeyEntity {
    @Attribute(.unique) public var id: UUID
    public var host: String
    public var hostLookup: String
    public var label: String
    public var algorithm: String
    public var keySource: String
    public var publicKeyOpenSSH: String
    public var keychainPrivateRef: String
    public var keychainPassphraseRef: String?
    public var isHostDefault: Bool

    public init(
        id: UUID,
        host: String,
        label: String,
        algorithm: String,
        keySource: String,
        publicKeyOpenSSH: String,
        keychainPrivateRef: String,
        keychainPassphraseRef: String?,
        isHostDefault: Bool
    ) {
        self.id = id
        self.host = host
        self.hostLookup = host.lowercased()
        self.label = label
        self.algorithm = algorithm
        self.keySource = keySource
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.keychainPrivateRef = keychainPrivateRef
        self.keychainPassphraseRef = keychainPassphraseRef
        self.isHostDefault = isHostDefault
    }
}

public enum StorageSchema {
    public static let models: [any PersistentModel.Type] = [
        RepoEntity.self,
        HostFingerprintEntity.self,
        SSHKeyEntity.self
    ]
}
