import SwiftUI
import SwiftData

@main
struct GitPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(
                appLock: container.appLock,
                viewModel: container.viewModel,
                hostTrustPrompter: container.hostTrustPrompter
            )
            .modelContainer(container.modelContainer)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                container.appLock.handleBecameActive()
            case .background:
                container.appLock.handleDidEnterBackground()
            default:
                break
            }
        }
    }
}
