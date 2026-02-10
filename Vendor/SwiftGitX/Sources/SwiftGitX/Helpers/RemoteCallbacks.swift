import Foundation
import libgit2

public struct SSHAuthentication: Sendable {
    public let username: String?
    public let privateKeyPath: String
    public let passphrase: String?
    public let acceptUntrustedHost: Bool

    public init(
        username: String?,
        privateKeyPath: String,
        passphrase: String? = nil,
        acceptUntrustedHost: Bool = true
    ) {
        self.username = username
        self.privateKeyPath = privateKeyPath
        self.passphrase = passphrase
        self.acceptUntrustedHost = acceptUntrustedHost
    }
}

final class RemoteCallbackPayload {
    let authentication: SSHAuthentication?
    let transferProgressHandler: TransferProgressHandler?

    init(authentication: SSHAuthentication?, transferProgressHandler: TransferProgressHandler?) {
        self.authentication = authentication
        self.transferProgressHandler = transferProgressHandler
    }
}

@inline(__always)
func makeRemoteCallbacks(
    authentication: SSHAuthentication?,
    transferProgressHandler: TransferProgressHandler?
) -> (callbacks: git_remote_callbacks, payload: UnsafeMutableRawPointer?) {
    var callbacks = git_remote_callbacks()
    git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))

    guard authentication != nil || transferProgressHandler != nil else {
        return (callbacks, nil)
    }

    let payloadObject = RemoteCallbackPayload(
        authentication: authentication,
        transferProgressHandler: transferProgressHandler
    )
    let payload = Unmanaged.passRetained(payloadObject).toOpaque()
    callbacks.payload = payload

    if authentication != nil {
        callbacks.credentials = credentialsCallback
        callbacks.certificate_check = certificateCheckCallback
    }

    if transferProgressHandler != nil {
        callbacks.transfer_progress = transferProgressCallback
    }

    return (callbacks, payload)
}

@inline(__always)
func releaseRemoteCallbacksPayload(_ payload: UnsafeMutableRawPointer?) {
    guard let payload else {
        return
    }
    Unmanaged<RemoteCallbackPayload>.fromOpaque(payload).release()
}

private let credentialsCallback: git_credential_acquire_cb = { out, _, usernameFromURL, allowedTypes, payload in
    guard let out else {
        return -1
    }

    guard let payload else {
        return -1
    }

    let payloadObject = Unmanaged<RemoteCallbackPayload>.fromOpaque(payload).takeUnretainedValue()
    guard let authentication = payloadObject.authentication else {
        return -1
    }

    let username = authentication.username
        ?? usernameFromURL.map { String(cString: $0) }
        ?? "git"
    let allowed = UInt32(allowedTypes)
    let usernameCredentialMask: UInt32 = 1 << 5
    let sshKeyCredentialMask: UInt32 = 1 << 1
    let sshMemoryCredentialMask: UInt32 = 1 << 6

    if (allowed & sshKeyCredentialMask) == 0 &&
        (allowed & sshMemoryCredentialMask) == 0 &&
        (allowed & usernameCredentialMask) != 0 {
        return username.withCString { usernamePointer in
            git_credential_username_new(out, usernamePointer)
        }
    }

    return username.withCString { usernamePointer in
        authentication.privateKeyPath.withCString { privateKeyPathPointer in
            if let passphrase = authentication.passphrase, !passphrase.isEmpty {
                return passphrase.withCString { passphrasePointer in
                    git_credential_ssh_key_new(
                        out,
                        usernamePointer,
                        nil,
                        privateKeyPathPointer,
                        passphrasePointer
                    )
                }
            }

            return git_credential_ssh_key_new(
                out,
                usernamePointer,
                nil,
                privateKeyPathPointer,
                nil
            )
        }
    }
}

private let certificateCheckCallback: git_transport_certificate_check_cb = { _, valid, _, payload in
    guard let payload else {
        return valid == 1 ? 0 : -1
    }

    let payloadObject = Unmanaged<RemoteCallbackPayload>.fromOpaque(payload).takeUnretainedValue()
    guard let authentication = payloadObject.authentication else {
        return valid == 1 ? 0 : -1
    }

    if authentication.acceptUntrustedHost {
        return 0
    }

    return valid == 1 ? 0 : -1
}

private let transferProgressCallback: git_indexer_progress_cb = { stats, payload in
    guard Task.isCancelled == false else {
        return 1
    }

    guard let payload else {
        return 0
    }

    let payloadObject = Unmanaged<RemoteCallbackPayload>.fromOpaque(payload).takeUnretainedValue()
    guard let handler = payloadObject.transferProgressHandler,
          let stats = stats?.pointee else {
        return 0
    }

    handler(TransferProgress(from: stats))
    return 0
}
