import Core
import CryptoKit
import Foundation
import Security

public enum SSHKeyAlgorithm: String, Sendable {
    case ed25519
    case rsa
}

public struct GeneratedSSHKey: Sendable {
    public var record: SSHKeyRecord
    public var privateKeyData: Data

    public init(record: SSHKeyRecord, privateKeyData: Data) {
        self.record = record
        self.privateKeyData = privateKeyData
    }
}

public struct SSHKeyManager: Sendable {
    private let keychain = KeychainSecretStore()

    public init() {}

    public func importPrivateKey(
        privateKeyData: Data,
        host: String,
        label: String,
        algorithm: SSHKeyAlgorithm,
        passphrase: String?
    ) throws -> SSHKeyRecord {
        let keyID = UUID()
        let privateRef = "ssh.private.\(keyID.uuidString)"

        try keychain.save(secret: privateKeyData, account: privateRef, requiresBiometry: true)

        var passphraseRef: String?
        if let passphrase, !passphrase.isEmpty {
            let ref = "ssh.passphrase.\(keyID.uuidString)"
            try keychain.save(secret: Data(passphrase.utf8), account: ref, requiresBiometry: true)
            passphraseRef = ref
        }

        return SSHKeyRecord(
            id: keyID,
            host: host,
            label: label,
            algorithm: algorithm.rawValue,
            keySource: "imported",
            publicKeyOpenSSH: "",
            keychainPrivateRef: privateRef,
            keychainPassphraseRef: passphraseRef
        )
    }

    public func generateKey(
        host: String,
        label: String,
        preferredAlgorithm: SSHKeyAlgorithm = .ed25519,
        passphrase: String?
    ) throws -> GeneratedSSHKey {
        switch preferredAlgorithm {
        case .ed25519:
            return try generateEd25519(host: host, label: label, passphrase: passphrase)
        case .rsa:
            return try generateRSA(host: host, label: label, passphrase: passphrase)
        }
    }

    public func loadPrivateKey(reference: String, prompt: String = "Authenticate to use your SSH private key") throws -> Data {
        try keychain.read(account: reference, prompt: prompt)
    }

    public func loadPassphrase(reference: String, prompt: String = "Authenticate to use your SSH key passphrase") throws -> String {
        let data = try keychain.read(account: reference, prompt: prompt)
        guard let value = String(data: data, encoding: .utf8) else {
            throw RepoError.keychainFailure("invalid passphrase encoding")
        }
        return value
    }

    public func deleteMaterial(privateRef: String, passphraseRef: String?) throws {
        try keychain.delete(account: privateRef)
        if let passphraseRef {
            try keychain.delete(account: passphraseRef)
        }
    }

    private func generateEd25519(host: String, label: String, passphrase: String?) throws -> GeneratedSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateData = privateKey.rawRepresentation
        let publicData = privateKey.publicKey.rawRepresentation
        let openSSHPublic = makeOpenSSHEd25519PublicKey(publicData)

        let keyID = UUID()
        let privateRef = "ssh.private.\(keyID.uuidString)"
        try keychain.save(secret: privateData, account: privateRef, requiresBiometry: true)

        var passphraseRef: String?
        if let passphrase, !passphrase.isEmpty {
            let ref = "ssh.passphrase.\(keyID.uuidString)"
            try keychain.save(secret: Data(passphrase.utf8), account: ref, requiresBiometry: true)
            passphraseRef = ref
        }

        let record = SSHKeyRecord(
            id: keyID,
            host: host,
            label: label,
            algorithm: SSHKeyAlgorithm.ed25519.rawValue,
            keySource: "generated",
            publicKeyOpenSSH: openSSHPublic,
            keychainPrivateRef: privateRef,
            keychainPassphraseRef: passphraseRef
        )

        return GeneratedSSHKey(record: record, privateKeyData: privateData)
    }

    private func generateRSA(host: String, label: String, passphrase: String?) throws -> GeneratedSSHKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 3072
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw RepoError.keychainFailure("RSA key generation failed: \(message)")
        }

        guard let privateBytes = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw RepoError.keychainFailure("RSA private key export failed: \(message)")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw RepoError.keychainFailure("RSA public key export failed")
        }

        let keyID = UUID()
        let privateRef = "ssh.private.\(keyID.uuidString)"
        try keychain.save(secret: privateBytes, account: privateRef, requiresBiometry: true)

        var passphraseRef: String?
        if let passphrase, !passphrase.isEmpty {
            let ref = "ssh.passphrase.\(keyID.uuidString)"
            try keychain.save(secret: Data(passphrase.utf8), account: ref, requiresBiometry: true)
            passphraseRef = ref
        }

        let openSSHPublic = "ssh-rsa \(publicBytes.base64EncodedString())"
        let record = SSHKeyRecord(
            id: keyID,
            host: host,
            label: label,
            algorithm: SSHKeyAlgorithm.rsa.rawValue,
            keySource: "generated",
            publicKeyOpenSSH: openSSHPublic,
            keychainPrivateRef: privateRef,
            keychainPassphraseRef: passphraseRef
        )

        return GeneratedSSHKey(record: record, privateKeyData: privateBytes)
    }

    private func makeOpenSSHEd25519PublicKey(_ publicRaw: Data) -> String {
        var blob = Data()
        blob.append(lengthPrefixed(Data("ssh-ed25519".utf8)))
        blob.append(lengthPrefixed(publicRaw))
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    private func lengthPrefixed(_ payload: Data) -> Data {
        var data = Data()
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { bytes in
            data.append(contentsOf: bytes)
        }
        data.append(payload)
        return data
    }
}
