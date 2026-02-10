import Core
import SwiftUI
import UIKit

enum AppColorTokens {
    static let accent = Color(red: 0.00, green: 0.56, blue: 0.84)
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue

    static let surfaceBackground = Color(UIColor.systemGroupedBackground)
    static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)

    static func tint(for state: RepoSyncState) -> Color {
        switch state {
        case .success:
            return success
        case .syncing:
            return info
        case .blockedDirty, .blockedDiverged, .hostMismatch, .networkDeferred:
            return warning
        case .failed, .authFailed:
            return error
        case .idle:
            return .secondary
        }
    }

    static func tint(for kind: RepoBannerMessage.Kind) -> Color {
        switch kind {
        case .info:
            return info
        case .success:
            return success
        case .warning:
            return warning
        case .error:
            return error
        }
    }
}
