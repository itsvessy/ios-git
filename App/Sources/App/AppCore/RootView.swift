import Foundation
import SecurityEngine
import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ObservedObject var appLock: AppLockCoordinator
    @ObservedObject var viewModel: RepoListViewModel
    @ObservedObject var hostTrustPrompter: HostTrustPrompter
    @ObservedObject var securityViewModel: SecurityCenterViewModel
    @ObservedObject var bannerCenter: AppBannerCenter
    let keyboardWarmupCoordinator: KeyboardWarmupCoordinator

    @State private var selectedSection: RootSidebarSection? = .repositories

    var body: some View {
        ZStack {
            if appLock.isUnlocked {
                unlockedShell
            } else {
                UnlockGateView(appLock: appLock)
            }

            if let request = hostTrustPrompter.pendingRequest {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                HostTrustPromptView(
                    request: request,
                    onReject: { hostTrustPrompter.reject() },
                    onApprove: { hostTrustPrompter.approve() }
                )
                .frame(maxWidth: 520)
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = bannerCenter.banner {
                AppBannerView(banner: banner)
                    .padding(.horizontal, AppSpacingTokens.large)
                    .padding(.bottom, AppSpacingTokens.large)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("global-banner")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: bannerCenter.banner?.id)
        .onAppear {
            keyboardWarmupCoordinator.warmupIfNeeded(isUnlocked: appLock.isUnlocked)
        }
        .onChange(of: appLock.isUnlocked) { _, isUnlocked in
            keyboardWarmupCoordinator.warmupIfNeeded(isUnlocked: isUnlocked)
        }
    }

    @ViewBuilder
    private var unlockedShell: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                List(RootSidebarSection.allCases, selection: $selectedSection) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
                .navigationTitle("GitPhone")
                .listStyle(.sidebar)
            } detail: {
                NavigationStack {
                    switch selectedSection ?? .repositories {
                    case .repositories:
                        RepoListView(
                            viewModel: viewModel,
                            securityViewModel: securityViewModel,
                            allowSecurityPush: false
                        )
                    case .security:
                        SecurityCenterView(viewModel: securityViewModel)
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                RepoListView(
                    viewModel: viewModel,
                    securityViewModel: securityViewModel,
                    allowSecurityPush: true
                )
            }
        }
    }
}

private enum RootSidebarSection: String, CaseIterable, Identifiable {
    case repositories
    case security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repositories:
            return "Repositories"
        case .security:
            return "Security"
        }
    }

    var symbolName: String {
        switch self {
        case .repositories:
            return "externaldrive"
        case .security:
            return "lock.shield"
        }
    }
}
