import Core
import Combine
import Foundation
import SecurityEngine
import Storage

@MainActor
final class SecurityCenterViewModel: ObservableObject {
    @Published private(set) var keys: [SSHKeyRecord] = []
    @Published private(set) var fingerprints: [HostFingerprintRecord] = []
    @Published private(set) var defaultKeyIDByHost: [String: UUID] = [:]
    @Published private(set) var logFileURL: URL?
    @Published private(set) var isRefreshing = false
    @Published var selectedRelockInterval: TimeInterval

    let relockIntervalOptions: [TimeInterval] = [60, 300, 900, 1800, 3600]

    private let repoStore: RepoStore
    private let keyManager: SSHKeyManager
    private let logger: AppLogger
    private let appLock: AppLockCoordinator
    private let bannerCenter: AppBannerCenter

    init(
        repoStore: RepoStore,
        keyManager: SSHKeyManager,
        logger: AppLogger,
        appLock: AppLockCoordinator,
        bannerCenter: AppBannerCenter
    ) {
        self.repoStore = repoStore
        self.keyManager = keyManager
        self.logger = logger
        self.appLock = appLock
        self.bannerCenter = bannerCenter
        self.selectedRelockInterval = appLock.relockInterval()
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            keys = try repoStore.listKeys()
                .sorted { lhs, rhs in
                    if lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedSame {
                        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                    }
                    return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
                }
            fingerprints = try repoStore.listFingerprints()

            let hosts = Set(keys.map { $0.host.lowercased() })
            var defaults: [String: UUID] = [:]
            for host in hosts {
                defaults[host] = try repoStore.defaultKey(host: host)?.id
            }
            defaultKeyIDByHost = defaults

            Task {
                let logURL = await logger.logFileURL()
                await MainActor.run {
                    self.logFileURL = logURL
                }
            }
        } catch {
            bannerCenter.show(
                RepoBannerMessage(
                    text: "Security data refresh failed: \(error.localizedDescription)",
                    kind: .error
                )
            )
        }
    }

    func defaultKeyID(for host: String) -> UUID? {
        defaultKeyIDByHost[host.lowercased()]
    }

    func lockNow() {
        appLock.lockNow()
        bannerCenter.show(RepoBannerMessage(text: "App locked.", kind: .info))
    }

    func setRelockInterval(_ interval: TimeInterval) {
        appLock.setRelockInterval(interval)
        selectedRelockInterval = appLock.relockInterval()
        bannerCenter.show(RepoBannerMessage(text: "Relock interval updated.", kind: .success))
    }

    func setDefaultKey(host: String, keyID: UUID) {
        do {
            try repoStore.setDefaultKey(host: host, keyID: keyID)
            refresh()
            bannerCenter.show(RepoBannerMessage(text: "Default key updated for \(host).", kind: .success))
        } catch {
            bannerCenter.show(
                RepoBannerMessage(
                    text: "Could not set default key for \(host): \(error.localizedDescription)",
                    kind: .error
                )
            )
        }
    }

    func deleteKey(_ key: SSHKeyRecord) {
        do {
            guard let deleted = try repoStore.deleteKey(id: key.id) else {
                return
            }

            do {
                try keyManager.deleteMaterial(
                    privateRef: deleted.keychainPrivateRef,
                    passphraseRef: deleted.keychainPassphraseRef
                )
            } catch {
                bannerCenter.show(
                    RepoBannerMessage(
                        text: "Key removed from app, but keychain cleanup failed.",
                        kind: .warning
                    )
                )
            }

            refresh()
            bannerCenter.show(RepoBannerMessage(text: "Deleted key \(deleted.label).", kind: .success))
        } catch {
            bannerCenter.show(
                RepoBannerMessage(
                    text: "Could not delete key \(key.label): \(error.localizedDescription)",
                    kind: .error
                )
            )
        }
    }

    func deleteFingerprint(_ fingerprint: HostFingerprintRecord) {
        do {
            try repoStore.deleteFingerprint(
                host: fingerprint.host,
                port: fingerprint.port,
                algorithm: fingerprint.algorithm
            )
            refresh()
            bannerCenter.show(RepoBannerMessage(text: "Removed trust pin for \(fingerprint.host).", kind: .success))
        } catch {
            bannerCenter.show(
                RepoBannerMessage(
                    text: "Could not remove trust pin: \(error.localizedDescription)",
                    kind: .error
                )
            )
        }
    }

    func clearLogs() async {
        do {
            try await logger.clearLogFile()
            let url = await logger.logFileURL()
            logFileURL = url
            bannerCenter.show(RepoBannerMessage(text: "Diagnostics log cleared.", kind: .success))
        } catch {
            bannerCenter.show(
                RepoBannerMessage(
                    text: "Could not clear diagnostics log: \(error.localizedDescription)",
                    kind: .error
                )
            )
        }
    }
}
