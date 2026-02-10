import Foundation

@MainActor
final class HostTrustPrompter: ObservableObject {
    struct PendingRequest: Identifiable {
        let id: UUID
        let host: String
        let fingerprint: String
        let algorithm: String
    }

    @Published private(set) var pendingRequest: PendingRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestApproval(host: String, fingerprint: String, algorithm: String) async -> Bool {
        await withCheckedContinuation { continuation in
            self.pendingRequest = PendingRequest(
                id: UUID(),
                host: host,
                fingerprint: fingerprint,
                algorithm: algorithm
            )
            self.continuation = continuation
        }
    }

    func approve() {
        resolve(true)
    }

    func reject() {
        resolve(false)
    }

    private func resolve(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
        pendingRequest = nil
    }
}
