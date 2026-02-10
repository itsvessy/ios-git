import Foundation
import SecurityEngine
import SwiftUI

struct UnlockGateView: View {
    @ObservedObject var appLock: AppLockCoordinator
    @State private var isUnlocking = false
    @State private var unlockError: String?

    var body: some View {
        VStack(spacing: AppSpacingTokens.large) {
            Spacer()

            AppCard {
                VStack(spacing: AppSpacingTokens.large) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(AppColorTokens.accent)

                    Text("GitPhone Locked")
                        .font(.title2.weight(.semibold))

                    Text("Authenticate to access repositories and SSH credentials.")
                        .font(AppTypography.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if let unlockError {
                        Text(unlockError)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColorTokens.error)
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
                    .accessibilityIdentifier("unlock-button")
                }
            }
            .frame(maxWidth: 420)

            Spacer()
        }
        .padding(AppSpacingTokens.xLarge)
        .background(AppColorTokens.surfaceBackground)
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
