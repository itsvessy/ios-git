//
//  Repository+clone.swift
//  SwiftGitX
//
//  Created by İbrahim Çetin on 23.11.2025.
//

import Foundation
import libgit2

extension Repository {
    // TODO: Fix blocking async - libgit2 calls block Swift's cooperative threads. Find a way to make it non-blocking.

    /// Clone a repository from the specified URL to the specified path.
    ///
    /// - Parameters:
    ///   - remoteURL: The URL of the repository to clone.
    ///   - localURL: The path to clone the repository to.
    ///   - options: The clone options. Defaults to `.default`.
    ///   - transferProgressHandler: An optional closure that is called with the transfer progress.
    ///
    /// - Returns: The cloned repository at the specified path.
    ///
    /// - Throws: `SwiftGitXError` if the repository cannot be cloned.
    public nonisolated static func clone(
        from remoteURL: URL,
        to localURL: URL,
        options: CloneOptions = .default,
        transferProgressHandler: TransferProgressHandler? = nil,
        authentication: SSHAuthentication? = nil
    ) async throws(SwiftGitXError) -> Repository {
        // Initialize the SwiftGitXRuntime
        try SwiftGitXRuntime.initialize()

        // Initialize the clone options
        var cloneOptions = options.gitCloneOptions
        cloneOptions.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        let callbacks = makeRemoteCallbacks(
            authentication: authentication,
            transferProgressHandler: transferProgressHandler
        )
        cloneOptions.fetch_opts.callbacks = callbacks.callbacks
        defer { releaseRemoteCallbacksPayload(callbacks.payload) }

        do {
            let pointer = try git(operation: .clone) {
                var pointer: OpaquePointer?
                let status = git_clone(&pointer, remoteURL.absoluteString, localURL.path, &cloneOptions)
                return (pointer, status)
            }

            return Repository(pointer: pointer)
        } catch {
            // Shutdown the SwiftGitXRuntime on error
            _ = try? SwiftGitXRuntime.shutdown()
            throw error
        }
    }
}
