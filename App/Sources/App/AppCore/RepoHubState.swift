import Core
import Foundation
import SwiftUI

enum RepoSortMode: String, CaseIterable, Identifiable {
    case name
    case lastSync
    case syncState

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return "Name"
        case .lastSync:
            return "Last Sync"
        case .syncState:
            return "State"
        }
    }
}

enum RepoStateFilter: String, CaseIterable, Identifiable {
    case all
    case synced
    case blocked
    case auth
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .synced:
            return "Synced"
        case .blocked:
            return "Blocked"
        case .auth:
            return "Auth"
        case .failed:
            return "Failed"
        }
    }

    func matches(state: RepoSyncState) -> Bool {
        switch self {
        case .all:
            return true
        case .synced:
            return state == .success
        case .blocked:
            return [.blockedDirty, .blockedDiverged, .hostMismatch, .networkDeferred].contains(state)
        case .auth:
            return state == .authFailed
        case .failed:
            return state == .failed
        }
    }
}

struct RepoBannerMessage: Identifiable, Equatable {
    enum Kind {
        case info
        case success
        case warning
        case error

        var symbolName: String {
            switch self {
            case .info:
                return "info.circle.fill"
            case .success:
                return "checkmark.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case .error:
                return "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let text: String
    let kind: Kind
}

@MainActor
final class AppBannerCenter: ObservableObject {
    @Published private(set) var banner: RepoBannerMessage?

    private var dismissTask: Task<Void, Never>?

    func show(_ message: RepoBannerMessage, autoDismissAfter seconds: TimeInterval = 3.5) {
        dismissTask?.cancel()
        banner = message

        guard seconds > 0 else {
            return
        }

        dismissTask = Task { [weak self] in
            let duration = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.banner = nil
            }
        }
    }

    func clear() {
        dismissTask?.cancel()
        banner = nil
    }
}

typealias RepoHubViewModel = RepoListViewModel
