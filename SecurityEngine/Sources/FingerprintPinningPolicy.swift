import Core
import Foundation

public actor FingerprintPinningPolicy: HostTrustEvaluator {
    public typealias Lookup = @Sendable (_ host: String, _ port: Int, _ algorithm: String) async throws -> HostFingerprintRecord?
    public typealias Persist = @Sendable (_ record: HostFingerprintRecord) async throws -> Void
    public typealias Prompt = @Sendable (_ host: String, _ fingerprint: String, _ algorithm: String) async -> Bool

    private let lookup: Lookup
    private let persist: Persist
    private let prompt: Prompt

    public init(lookup: @escaping Lookup, persist: @escaping Persist, prompt: @escaping Prompt) {
        self.lookup = lookup
        self.persist = persist
        self.prompt = prompt
    }

    public func evaluate(host: String, port: Int, presentedFingerprint: String, algorithm: String) async throws -> TrustDecision {
        if let existing = try await lookup(host, port, algorithm) {
            if existing.fingerprintSHA256 == presentedFingerprint {
                return .alreadyTrusted
            }

            let userApprovedRotation = await prompt(host, presentedFingerprint, algorithm)
            guard userApprovedRotation else {
                throw RepoError.hostMismatch(expected: existing.fingerprintSHA256, got: presentedFingerprint)
            }

            let updated = HostFingerprintRecord(
                host: host,
                port: port,
                algorithm: algorithm,
                fingerprintSHA256: presentedFingerprint,
                acceptedAt: Date()
            )
            try await persist(updated)
            return .trustAndPin
        }

        let userApproved = await prompt(host, presentedFingerprint, algorithm)
        guard userApproved else {
            throw RepoError.hostTrustRejected
        }

        let firstTrust = HostFingerprintRecord(
            host: host,
            port: port,
            algorithm: algorithm,
            fingerprintSHA256: presentedFingerprint,
            acceptedAt: Date()
        )
        try await persist(firstTrust)
        return .trustAndPin
    }
}
