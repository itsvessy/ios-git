import Core
import SwiftUI

struct StatusChip: View {
    let state: RepoSyncState

    var body: some View {
        Text(state.shortLabel)
            .font(AppTypography.caption.weight(.semibold))
            .padding(.horizontal, AppSpacingTokens.small)
            .padding(.vertical, AppSpacingTokens.xSmall)
            .foregroundStyle(AppColorTokens.tint(for: state))
            .background(AppColorTokens.tint(for: state).opacity(0.14))
            .clipShape(Capsule())
            .accessibilityLabel("Sync state: \(state.longLabel)")
    }
}

extension RepoSyncState {
    var shortLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .syncing:
            return "Syncing"
        case .success:
            return "Synced"
        case .blockedDirty, .blockedDiverged:
            return "Blocked"
        case .authFailed:
            return "Auth"
        case .hostMismatch:
            return "Host"
        case .networkDeferred:
            return "Deferred"
        case .failed:
            return "Failed"
        }
    }

    var longLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .syncing:
            return "Syncing in progress"
        case .success:
            return "Synced"
        case .blockedDirty:
            return "Blocked by local changes"
        case .blockedDiverged:
            return "Blocked by diverged history"
        case .authFailed:
            return "Authentication failed"
        case .hostMismatch:
            return "Host key mismatch"
        case .networkDeferred:
            return "Background sync deferred"
        case .failed:
            return "Failed"
        }
    }
}
