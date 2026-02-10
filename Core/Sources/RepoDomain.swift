import Foundation

public struct RepoID: Hashable, Codable, Sendable, Identifiable {
    public var rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum RepoSyncState: String, Codable, Sendable {
    case idle
    case syncing
    case success
    case blockedDirty
    case blockedDiverged
    case authFailed
    case hostMismatch
    case networkDeferred
    case failed
}

public enum SyncTrigger: String, Codable, Sendable {
    case manual
    case background
}

public struct RepoRecord: Codable, Sendable, Identifiable {
    public let id: RepoID
    public var displayName: String
    public var remoteURL: String
    public var localPath: String
    public var securityScopedBookmark: Data?
    public var trackedBranch: String
    public var sshKeyOverrideID: UUID?
    public var autoSyncEnabled: Bool
    public var lastSyncAt: Date?
    public var lastSyncState: RepoSyncState
    public var lastErrorMessage: String?

    public init(
        id: RepoID,
        displayName: String,
        remoteURL: String,
        localPath: String,
        securityScopedBookmark: Data? = nil,
        trackedBranch: String,
        sshKeyOverrideID: UUID? = nil,
        autoSyncEnabled: Bool,
        lastSyncAt: Date? = nil,
        lastSyncState: RepoSyncState = .idle,
        lastErrorMessage: String? = nil
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
        self.lastSyncState = lastSyncState
        self.lastErrorMessage = lastErrorMessage
    }
}

public struct HostFingerprintRecord: Codable, Sendable {
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
    }
}

public struct SSHKeyRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var host: String
    public var label: String
    public var algorithm: String
    public var keySource: String
    public var publicKeyOpenSSH: String
    public var keychainPrivateRef: String
    public var keychainPassphraseRef: String?

    public init(
        id: UUID = UUID(),
        host: String,
        label: String,
        algorithm: String,
        keySource: String,
        publicKeyOpenSSH: String,
        keychainPrivateRef: String,
        keychainPassphraseRef: String?
    ) {
        self.id = id
        self.host = host
        self.label = label
        self.algorithm = algorithm
        self.keySource = keySource
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.keychainPrivateRef = keychainPrivateRef
        self.keychainPassphraseRef = keychainPassphraseRef
    }
}

public struct CloneRequest: Sendable {
    public var displayName: String
    public var remoteURL: String
    public var targetDirectory: URL
    public var targetDirectoryBookmark: Data?
    public var trackedBranch: String
    public var autoSyncEnabled: Bool

    public init(
        displayName: String,
        remoteURL: String,
        targetDirectory: URL,
        targetDirectoryBookmark: Data? = nil,
        trackedBranch: String,
        autoSyncEnabled: Bool
    ) {
        self.displayName = displayName
        self.remoteURL = remoteURL
        self.targetDirectory = targetDirectory
        self.targetDirectoryBookmark = targetDirectoryBookmark
        self.trackedBranch = trackedBranch
        self.autoSyncEnabled = autoSyncEnabled
    }
}

public struct SyncResult: Sendable {
    public var state: RepoSyncState
    public var message: String?
    public var completedAt: Date

    public init(state: RepoSyncState, message: String? = nil, completedAt: Date = Date()) {
        self.state = state
        self.message = message
        self.completedAt = completedAt
    }
}

public struct RemoteProbeResult: Sendable {
    public var host: String
    public var port: Int
    public var normalizedURL: String

    public init(host: String, port: Int, normalizedURL: String) {
        self.host = host
        self.port = port
        self.normalizedURL = normalizedURL
    }
}

public enum TrustDecision: Sendable {
    case trustAndPin
    case reject
    case alreadyTrusted
}

public struct SSHCredentialMaterial: Sendable {
    public var username: String
    public var privateKey: Data
    public var passphrase: String?

    public init(username: String, privateKey: Data, passphrase: String? = nil) {
        self.username = username
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}

public protocol GitClient: Sendable {
    func prepareRemote(_ remoteURL: String) async throws -> RemoteProbeResult
    func clone(_ request: CloneRequest) async throws -> RepoRecord
    func sync(_ repo: RepoRecord, trigger: SyncTrigger) async throws -> SyncResult
    func probeRemote(_ remoteURL: String) async throws -> RemoteProbeResult
}

public protocol HostTrustEvaluator: Sendable {
    func evaluate(host: String, port: Int, presentedFingerprint: String, algorithm: String) async throws -> TrustDecision
}

public protocol SSHCredentialProvider: Sendable {
    func credential(for host: String, username: String?) async throws -> SSHCredentialMaterial
}

public enum RepoError: LocalizedError, Sendable {
    case invalidRemoteURL
    case unsupportedRemoteScheme
    case hostTrustRejected
    case hostMismatch(expected: String, got: String)
    case dirtyWorkingTree
    case divergedBranch
    case keyNotFound
    case keychainFailure(String)
    case syncBlocked(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRemoteURL:
            return "The remote URL is invalid."
        case .unsupportedRemoteScheme:
            return "Only SSH Git URLs are supported."
        case .hostTrustRejected:
            return "The SSH host key was rejected."
        case let .hostMismatch(expected, got):
            return "SSH host key mismatch. Expected \(expected), got \(got)."
        case .dirtyWorkingTree:
            return "Sync blocked because local files have uncommitted changes."
        case .divergedBranch:
            return "Sync blocked because local and remote branches have diverged."
        case .keyNotFound:
            return "No SSH key is configured for this host."
        case let .keychainFailure(message):
            return "Keychain error: \(message)"
        case let .syncBlocked(message):
            return "Sync blocked: \(message)"
        case let .ioFailure(message):
            return "File error: \(message)"
        }
    }
}
