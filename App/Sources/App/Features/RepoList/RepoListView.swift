import Core
import Foundation
import SwiftUI

struct RepoListView: View {
    @ObservedObject var viewModel: RepoListViewModel
    @ObservedObject var securityViewModel: SecurityCenterViewModel
    let allowSecurityPush: Bool
    private let rowHorizontalInset = AppSpacingTokens.large

    @State private var pendingDeleteRepo: RepoRecord?
    @State private var pendingDiscardRepo: RepoRecord?
    @State private var isPresentingAddRepo = false
    @State private var isPresentingSecurity = false
    @State private var selectedRepoForFilesID: RepoID?
    @State private var selectedRepoForGitActions: RepoRecord?

    var body: some View {
        repoList
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColorTokens.surfaceBackground)
        .navigationTitle("Repositories")
        .searchable(text: $viewModel.searchQuery, prompt: "Search name, remote, or branch")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $viewModel.sortMode) {
                        ForEach(RepoSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                }

                if allowSecurityPush {
                    Button {
                        isPresentingSecurity = true
                    } label: {
                        Label("Security", systemImage: "lock.shield")
                    }
                }

                Button {
                    isPresentingAddRepo = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $isPresentingAddRepo) {
            AddRepoView(viewModel: viewModel)
        }
        .navigationDestination(item: $selectedRepoForFilesID) { repoID in
            if let repo = viewModel.repos.first(where: { $0.id == repoID }) {
                RepoFilesView(repo: repo, viewModel: viewModel)
            } else {
                Text("Repository not found.")
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selectedRepoForGitActions) { repo in
            RepoGitActionsSheet(repo: repo, viewModel: viewModel)
        }
        .navigationDestination(isPresented: $isPresentingSecurity) {
            SecurityCenterView(viewModel: securityViewModel)
        }
        .confirmationDialog(
            "Delete Repository?",
            isPresented: Binding(
                get: { pendingDeleteRepo != nil },
                set: { if !$0 { pendingDeleteRepo = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteRepo
        ) { repo in
            Button("Remove from GitPhone", role: .destructive) {
                Task {
                    await viewModel.deleteRepo(repo: repo, removeFiles: false)
                }
                pendingDeleteRepo = nil
            }
            Button("Remove and Delete Files", role: .destructive) {
                Task {
                    await viewModel.deleteRepo(repo: repo, removeFiles: true)
                }
                pendingDeleteRepo = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteRepo = nil
            }
        } message: { repo in
            Text("Choose whether to remove only this repo entry or also delete local files at \(repo.localPath).")
        }
        .confirmationDialog(
            "Discard Local Changes?",
            isPresented: Binding(
                get: { pendingDiscardRepo != nil },
                set: { if !$0 { pendingDiscardRepo = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDiscardRepo
        ) { repo in
            Button("Discard", role: .destructive) {
                Task {
                    await viewModel.discardLocalChanges(repo: repo)
                }
                pendingDiscardRepo = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDiscardRepo = nil
            }
        } message: { repo in
            Text("This will delete all uncommitted changes in \(repo.displayName), including untracked files.")
        }
        .task {
            await viewModel.refresh()
        }
    }

    private var repoList: some View {
        List {
            filterSection
            repositoriesSection
        }
    }

    private var filterSection: some View {
        Section {
            filterStrip
                .listRowInsets(EdgeInsets(top: 0, leading: rowHorizontalInset, bottom: 0, trailing: rowHorizontalInset))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var repositoriesSection: some View {
        if viewModel.repos.isEmpty {
            Section {
                AppEmptyState(
                    title: "No Repositories",
                    systemImage: "externaldrive.badge.plus",
                    description: "Clone an SSH repository to start syncing."
                )
                .listRowSeparator(.hidden)
            }
        } else if viewModel.visibleRepos.isEmpty {
            Section {
                AppEmptyState(
                    title: "No Matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: "Try a different search query or filter."
                )
                .listRowSeparator(.hidden)
            }
        } else {
            Section {
                ForEach(viewModel.visibleRepos) { repo in
                    RepoRowView(
                        repo: repo,
                        viewModel: viewModel,
                        onDelete: { pendingDeleteRepo = $0 },
                        onOpenFiles: { selectedRepoForFilesID = $0 },
                        onOpenGitActions: { selectedRepoForGitActions = $0 },
                        onDiscard: { pendingDiscardRepo = $0 }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: rowHorizontalInset, bottom: 6, trailing: rowHorizontalInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteRepo = repo
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Repositories (\(viewModel.visibleRepos.count))")
            }
        }
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacingTokens.small) {
                ForEach(RepoStateFilter.allCases) { filter in
                    Button {
                        viewModel.stateFilter = filter
                    } label: {
                        Text("\(filter.title) \(viewModel.count(for: filter))")
                    }
                    .buttonStyle(FilterPillButtonStyle(isSelected: viewModel.stateFilter == filter))
                }
            }
            .padding(.horizontal, AppSpacingTokens.xSmall)
        }
    }
}

private struct RepoRowView: View {
    let repo: RepoRecord
    @ObservedObject var viewModel: RepoListViewModel
    let onDelete: (RepoRecord) -> Void
    let onOpenFiles: (RepoID) -> Void
    let onOpenGitActions: (RepoRecord) -> Void
    let onDiscard: (RepoRecord) -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
                HStack(alignment: .top, spacing: AppSpacingTokens.small) {
                    VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacingTokens.small) {
                            Text(repo.displayName)
                                .font(AppTypography.title)
                                .lineLimit(1)

                            Spacer(minLength: 8)
                            StatusChip(state: repo.lastSyncState)
                        }

                        Text(repo.remoteURL)
                            .font(AppTypography.captionMonospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: AppSpacingTokens.xSmall) {
                        syncButton
                        moreMenu
                    }
                }

                HStack(spacing: AppSpacingTokens.small) {
                    Text("Auto")
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Auto Sync", isOn: Binding(
                        get: { repo.autoSyncEnabled },
                        set: { newValue in
                            Task {
                                await viewModel.setAutoSync(repo: repo, enabled: newValue)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppColorTokens.accent)

                    Spacer(minLength: 8)

                    Image(systemName: "folder")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColorTokens.accent)
                        .accessibilityHidden(true)
                }

                if let lastSyncAt = repo.lastSyncAt {
                    Text("Last sync: \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = repo.lastErrorMessage {
                    Text(displayMessage(for: message))
                        .font(AppTypography.caption)
                        .foregroundStyle(messageColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFiles(repo.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens repository files")
    }

    private var messageColor: Color {
        repo.lastSyncState == .success ? .secondary : AppColorTokens.error
    }

    private func displayMessage(for raw: String) -> String {
        guard repo.lastSyncState == .success else {
            return raw
        }

        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "already up to date." || normalized == "already up to date" {
            return "Up to date."
        }
        return raw
    }

    private var syncButton: some View {
        Button {
            Task {
                await viewModel.sync(repo: repo)
            }
        } label: {
            if viewModel.isSyncing(repoID: repo.id) {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(AppColorTokens.accent)
        .disabled(viewModel.isSyncing(repoID: repo.id) || viewModel.isGitActionInProgress(repoID: repo.id))
        .accessibilityLabel(viewModel.isSyncing(repoID: repo.id) ? "Syncing repository" : "Sync repository")
    }

    private var moreMenu: some View {
        Menu {
            Button("Git Actions") {
                onOpenGitActions(repo)
            }

            Button("Discard Local Changes", role: .destructive) {
                onDiscard(repo)
            }

            Button("Reset to Remote") {
                Task {
                    await viewModel.resetToRemote(repo: repo)
                }
            }

            Divider()
            Button(role: .destructive) {
                onDelete(repo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(AppColorTokens.accent)
        .accessibilityLabel("More actions")
        .disabled(viewModel.isGitActionInProgress(repoID: repo.id))
    }
}

private struct FilterPillButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.caption.weight(.semibold))
            .padding(.horizontal, AppSpacingTokens.medium)
            .padding(.vertical, AppSpacingTokens.small)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AppColorTokens.accent : AppColorTokens.cardBackground)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
