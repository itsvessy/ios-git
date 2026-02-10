import Core
import Combine
import Foundation
import LocalAuthentication
import Security

public struct KeychainSecretStore: Sendable {
    public init() {}

    public func save(secret: Data, account: String, requiresBiometry: Bool) throws {
        try delete(account: account)

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account,
            kSecValueData: secret
        ]

        if requiresBiometry {
            let flags: SecAccessControlCreateFlags = [.userPresence]
            guard let accessControl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
                throw RepoError.keychainFailure("failed to create access control")
            }
            query[kSecAttrAccessControl] = accessControl
        } else {
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RepoError.keychainFailure("save failed with status \(status)")
        }
    }

    public func read(account: String, prompt: String? = nil) throws -> Data {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        if let prompt {
            let context = LAContext()
            context.localizedReason = prompt
            query[kSecUseAuthenticationContext] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw RepoError.keychainFailure("read failed with status \(status)")
        }

        guard let data = item as? Data else {
            throw RepoError.keychainFailure("read returned invalid payload")
        }

        return data
    }

    public func delete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RepoError.keychainFailure("delete failed with status \(status)")
        }
    }

    public func exists(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private var serviceName: String {
        "com.vessy.GitPhone.secrets"
    }
}

@MainActor
public final class AppLockCoordinator: ObservableObject {
    @Published public private(set) var isUnlocked = false

    private var lastBackgroundDate: Date?
    private var relockIntervalSeconds: TimeInterval

    public init(relockInterval: TimeInterval = 30 * 60) {
        self.relockIntervalSeconds = max(1, relockInterval)
    }

    public func handleBecameActive() {
        guard let lastBackgroundDate else {
            return
        }

        if Date().timeIntervalSince(lastBackgroundDate) >= relockIntervalSeconds {
            isUnlocked = false
        }
    }

    public func handleDidEnterBackground() {
        lastBackgroundDate = Date()
    }

    public func markUnlocked() {
        isUnlocked = true
    }

    public func lockNow() {
        isUnlocked = false
        lastBackgroundDate = Date()
    }

    public func setRelockInterval(_ interval: TimeInterval) {
        relockIntervalSeconds = max(1, interval)
    }

    public func relockInterval() -> TimeInterval {
        relockIntervalSeconds
    }

    public func unlock(prompt: String = "Unlock GitPhone") async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = true
            return true
        }

        do {
            let success = try await evaluate(policy: .deviceOwnerAuthentication, context: context, reason: prompt)
            isUnlocked = success
            return success
        } catch {
            isUnlocked = false
            return false
        }
    }

    private func evaluate(policy: LAPolicy, context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: success)
            }
        }
    }
}
