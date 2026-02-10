import Foundation
import SecurityEngine
import SwiftUI

struct UnlockGateView: View {
    @ObservedObject var appLock: AppLockCoordinator
    @State private var isUnlocking = false
    @State private var unlockError: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)

            Text("GitPhone Locked")
                .font(.title2.bold())

            Text("Authenticate to access repositories and SSH credentials.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let unlockError {
                Text(unlockError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Button {
                Task {
                    await unlock()
                }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isUnlocking)
        }
        .padding(24)
        .task {
            if !appLock.isUnlocked {
                await unlock()
            }
        }
    }

    private func unlock() async {
        isUnlocking = true
        defer { isUnlocking = false }

        let success = await appLock.unlock()
        unlockError = success ? nil : "Authentication failed."
    }
}
