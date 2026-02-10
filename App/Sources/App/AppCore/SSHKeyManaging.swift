import Core
import Foundation
import SecurityEngine

protocol SSHKeyManaging: Sendable {
    func generateKey(
        host: String,
        label: String,
        preferredAlgorithm: SSHKeyAlgorithm,
        passphrase: String?
    ) throws -> GeneratedSSHKey

    func loadPrivateKey(reference: String, prompt: String) throws -> Data
    func loadPassphrase(reference: String, prompt: String) throws -> String
    func deleteMaterial(privateRef: String, passphraseRef: String?) throws
}

extension SSHKeyManager: SSHKeyManaging {}
