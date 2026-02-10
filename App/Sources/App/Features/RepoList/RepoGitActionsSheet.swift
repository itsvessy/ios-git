import Core
import SwiftUI

struct RepoGitActionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repo: RepoRecord
    @ObservedObject var viewModel: RepoListViewModel

    @State private var localChanges: [RepoLocalChange] = []
    @State private var commitMessage = ""
    @State private var quickCommitMessage = ""
    @State private var isQuickFlowExpanded = false
    @State private var identityName = ""
    @State private var identityEmail = ""
    @State private var isIdentityMissing = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    Text(repo.displayName)
                        .font(AppTypography.headline)
                    Text(repo.remoteURL)
                        .font(AppTypography.captionMonospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Section("Changed Files (\(localChanges.count))") {
                    if localChanges.isEmpty {
                        Text("No local changes detected.")
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(localChanges) { change in
                            HStack(spacing: AppSpacingTokens.small) {
                                Text(change.path)
                                    .font(AppTypography.captionMonospaced)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(change.stageState.rawValue.capitalized)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(.secondary)
                                Text(change.kind.rawValue.capitalized)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if isIdentityMissing {
                    Section("Commit Identity Required") {
                        TextField("Name", text: $identityName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                        TextField("Email", text: $identityEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)

                        Button("Save Identity") {
                            Task {
                                _ = await saveIdentityIfValid()
                            }
                        }
                        .disabled(isBusy || identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            identityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Quick Add, Commit & Push") {
                    Button(isQuickFlowExpanded ? "Hide Quick Flow" : "Quick Add, Commit & Push") {
                        isQuickFlowExpanded.toggle()
                    }
                    .disabled(isBusy)

                    if isQuickFlowExpanded {
                        TextEditor(text: $quickCommitMessage)
                            .frame(minHeight: 90)
                            .font(AppTypography.body)

                        Button("Push All") {
                            Task {
                                guard await ensureIdentityReady() else {
                                    return
                                }
                                let success = await viewModel.quickAddCommitPush(
                                    repo: repo,
                                    message: quickCommitMessage
                                )
                                if success {
                                    quickCommitMessage = ""
                                    await reloadLocalChanges()
                                }
                            }
                        }
                        .disabled(isBusy || quickCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section("Explicit Actions") {
                    Button("Add All") {
                        Task {
                            let success = await viewModel.stageAll(repo: repo)
                            if success {
                                await reloadLocalChanges()
                            }
                        }
                    }
                    .disabled(isBusy || localChanges.isEmpty)

                    TextEditor(text: $commitMessage)
                        .frame(minHeight: 90)
                        .font(AppTypography.body)

                    Button("Commit") {
                        Task {
                            guard await ensureIdentityReady() else {
                                return
                            }
                            let success = await viewModel.commit(repo: repo, message: commitMessage)
                            if success {
                                commitMessage = ""
                                await reloadLocalChanges()
                            }
                        }
                    }
                    .disabled(isBusy || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Push") {
                        Task {
                            _ = await viewModel.push(repo: repo)
                            await reloadLocalChanges()
                        }
                    }
                    .disabled(isBusy)
                }
            }
            .navigationTitle("Git Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await reloadState()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                }
            }
            .task {
                await reloadState()
            }
        }
    }

    private var isBusy: Bool {
        viewModel.isGitActionInProgress(repoID: repo.id) || viewModel.isSyncing(repoID: repo.id)
    }

    private func reloadState() async {
        await reloadLocalChanges()
        let identity = await viewModel.loadCommitIdentity(repo: repo)
        if let identity {
            identityName = identity.name
            identityEmail = identity.email
            isIdentityMissing = false
        } else {
            isIdentityMissing = true
        }
    }

    private func reloadLocalChanges() async {
        localChanges = await viewModel.loadLocalChanges(repo: repo)
    }

    private func ensureIdentityReady() async -> Bool {
        if !isIdentityMissing {
            return true
        }
        return await saveIdentityIfValid()
    }

    private func saveIdentityIfValid() async -> Bool {
        let trimmedName = identityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedEmail.isEmpty else {
            return false
        }

        let saved = await viewModel.saveCommitIdentity(
            repo: repo,
            name: trimmedName,
            email: trimmedEmail
        )
        if saved {
            isIdentityMissing = false
        }
        return saved
    }
}
