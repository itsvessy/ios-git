import Core
import Foundation
import SwiftUI

struct RepoListView: View {
    @ObservedObject var viewModel: RepoListViewModel
    @ObservedObject var hostTrustPrompter: HostTrustPrompter
    @State private var pendingDeleteRepo: RepoRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Background sync runs best-effort every 6 hours on Wi-Fi only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.repos.isEmpty {
                    ContentUnavailableView(
                        "No Repositories",
                        systemImage: "externaldrive.badge.plus",
                        description: Text("Clone an SSH repository to start syncing.")
                    )
                } else {
                    ForEach(viewModel.repos) { repo in
                        RepoRowView(
                            repo: repo,
                            viewModel: viewModel,
                            onDelete: { pendingDeleteRepo = $0 }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteRepo = repo
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Repositories")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.isPresentingPublicKeys = true
                    } label: {
                        Label("Keys", systemImage: "key.horizontal")
                    }

                    Button {
                        viewModel.isPresentingAddRepo = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $viewModel.isPresentingAddRepo) {
                AddRepoView(
                    viewModel: viewModel,
                    hostTrustPrompter: hostTrustPrompter
                )
            }
            .sheet(isPresented: $viewModel.isPresentingPublicKeys) {
                PublicKeysView(viewModel: viewModel)
            }
            .confirmationDialog(
                "Delete Repository?",
                isPresented: Binding(
                    get: { pendingDeleteRepo != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingDeleteRepo = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteRepo
            ) { repo in
                Button("Remove from GitPhone", role: .destructive) {
                    viewModel.deleteRepo(repo: repo, removeFiles: false)
                    pendingDeleteRepo = nil
                }
                Button("Remove and Delete Files", role: .destructive) {
                    viewModel.deleteRepo(repo: repo, removeFiles: true)
                    pendingDeleteRepo = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteRepo = nil
                }
            } message: { repo in
                Text("Choose whether to remove only this repo entry or also delete its local files at \(repo.localPath).")
            }
            .overlay(alignment: .bottom) {
                if let message = viewModel.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .padding()
                }
            }
            .task {
                viewModel.refresh()
            }
        }
    }
}

private struct RepoRowView: View {
    let repo: RepoRecord
    @ObservedObject var viewModel: RepoListViewModel
    let onDelete: (RepoRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repo.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(stateLabel)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateTint.opacity(0.15))
                    .foregroundStyle(stateTint)
                    .clipShape(Capsule())
            }

            Text(repo.remoteURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    autoSyncToggle
                    Spacer(minLength: 8)
                    syncButton
                }

                HStack(spacing: 8) {
                    filesButton
                    moreMenu
                }
            }

            if let lastSyncAt = repo.lastSyncAt {
                Text("Last sync: \(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = repo.lastErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }

    private var autoSyncToggle: some View {
        Toggle("Auto", isOn: Binding(
            get: { repo.autoSyncEnabled },
            set: { newValue in
                viewModel.setAutoSync(repo: repo, enabled: newValue)
            }
        ))
        .toggleStyle(.switch)
        .font(.subheadline)
        .lineLimit(1)
        .layoutPriority(1)
    }

    private var filesButton: some View {
        NavigationLink {
            RepoFilesView(repo: repo)
        } label: {
            Label("Files", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .controlSize(.regular)
    }

    private var syncButton: some View {
        Button {
            Task {
                await viewModel.sync(repo: repo)
            }
        } label: {
            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    private var moreMenu: some View {
        Menu {
            Button("Discard Local Changes") {
                viewModel.discardLocalChanges(repo: repo)
            }
            Button("Reset Diverged Marker") {
                viewModel.resolveDivergedByReset(repo: repo)
            }
            Divider()
            Button(role: .destructive) {
                onDelete(repo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var stateLabel: String {
        switch repo.lastSyncState {
        case .idle:
            return "Idle"
        case .syncing:
            return "Syncing"
        case .success:
            return "Synced"
        case .blockedDirty, .blockedDiverged:
            return "Blocked"
        case .networkDeferred:
            return "Deferred"
        case .failed:
            return "Failed"
        case .authFailed:
            return "Auth"
        case .hostMismatch:
            return "Host"
        }
    }

    private var stateTint: Color {
        switch repo.lastSyncState {
        case .success:
            return .green
        case .syncing:
            return .blue
        case .blockedDirty, .blockedDiverged, .hostMismatch:
            return .orange
        case .failed, .authFailed:
            return .red
        default:
            return .secondary
        }
    }
}
