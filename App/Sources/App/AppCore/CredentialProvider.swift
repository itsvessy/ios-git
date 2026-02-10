import Core
import Foundation
import SecurityEngine

actor StoreCredentialProvider: SSHCredentialProvider {
    typealias LookupKey = @Sendable (_ host: String) async throws -> SSHKeyRecord?

    private let lookupKey: LookupKey
    private let keyManager: any SSHKeyManaging

    init(lookupKey: @escaping LookupKey, keyManager: any SSHKeyManaging) {
        self.lookupKey = lookupKey
        self.keyManager = keyManager
    }

    func credential(for host: String, username: String?) async throws -> SSHCredentialMaterial {
        guard let key = try await lookupKey(host) else {
            throw RepoError.keyNotFound
        }

        let privateKey = try keyManager.loadPrivateKey(
            reference: key.keychainPrivateRef,
            prompt: "Authenticate to use your SSH private key"
        )
        var passphrase: String?
        if let passphraseRef = key.keychainPassphraseRef {
            passphrase = try keyManager.loadPassphrase(
                reference: passphraseRef,
                prompt: "Authenticate to use your SSH key passphrase"
            )
        }

        return SSHCredentialMaterial(
            username: username ?? "git",
            privateKey: privateKey,
            passphrase: passphrase
        )
    }
}
