import Foundation
import SecurityEngine
import SwiftUI

struct RootView: View {
    @ObservedObject var appLock: AppLockCoordinator
    @ObservedObject var viewModel: RepoListViewModel
    @ObservedObject var hostTrustPrompter: HostTrustPrompter

    var body: some View {
        ZStack {
            if appLock.isUnlocked {
                RepoListView(
                    viewModel: viewModel,
                    hostTrustPrompter: hostTrustPrompter
                )
            } else {
                UnlockGateView(appLock: appLock)
            }

            if let request = hostTrustPrompter.pendingRequest {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Trust SSH Host")
                        .font(.headline)
                    Text("Host: \(request.host)")
                        .font(.subheadline)
                    Text("Algorithm: \(request.algorithm)")
                        .font(.subheadline)
                    Text("Fingerprint:")
                        .font(.subheadline)
                    Text(request.fingerprint)
                        .font(.footnote)
                        .textSelection(.enabled)

                    HStack {
                        Button("Reject", role: .destructive) {
                            hostTrustPrompter.reject()
                        }
                        Spacer()
                        Button("Trust & Pin") {
                            hostTrustPrompter.approve()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding()
            }
        }
    }
}
