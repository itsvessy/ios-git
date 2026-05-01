import Core
import SwiftUI

enum RepoGitActionsPresentationMode: String, Sendable {
    case quick
    case advanced
}

extension RepoGitActionsPresentationMode: Identifiable {
    var id: String { rawValue }
}

struct RepoGitActionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let repo: RepoRecord
    @ObservedObject var viewModel: RepoListViewModel
    let presentationMode: RepoGitActionsPresentationMode

    @State private var localChanges: [RepoLocalChange] = []
    @State private var selectedChangePaths: Set<String> = []
    @State private var commitMessage = ""
    @State private var advancedCommitMessage = ""
    @State private var identityName = ""
    @State private var identityEmail = ""
    @State private var isIdentityMissing = true
    @State private var isEditingIdentity = false
    @State private var isAdvancedExpanded: Bool
    @State private var isShowingDiscardConfirmation = false
    @State private var isShowingResetConfirmation = false

    init(
        repo: RepoRecord,
        viewModel: RepoListViewModel,
        presentationMode: RepoGitActionsPresentationMode = .quick
    ) {
        self.repo = repo
        self.viewModel = viewModel
        self.presentationMode = presentationMode
        _isAdvancedExpanded = State(initialValue: presentationMode == .advanced)
    }

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

                Section("Commit Identity") {
                    if isIdentityMissing || isEditingIdentity {
                        TextField("Name", text: $identityName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                        TextField("Email", text: $identityEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)

                        Button {
                            Task {
                                _ = await saveIdentityIfValid()
                            }
                        } label: {
                            Label("Save Identity", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(
                            isBusy ||
                            identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            identityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        if !isIdentityMissing {
                            Button("Cancel") {
                                isEditingIdentity = false
                            }
                            .disabled(isBusy)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: AppSpacingTokens.xSmall) {
                            Text(identityName)
                                .font(AppTypography.body.weight(.semibold))
                            Text(identityEmail)
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Edit Identity") {
                            isEditingIdentity = true
                        }
                        .disabled(isBusy)
                    }
                }

                Section("Quick Commit & Push") {
                    TextEditor(text: $commitMessage)
                        .frame(minHeight: 96)
                        .font(AppTypography.body)

                    Button {
                        Task {
                            guard await ensureIdentityReady() else {
                                return
                            }

                            let success = await viewModel.quickAddCommitPush(
                                repo: repo,
                                message: commitMessage
                            )
                            if success {
                                commitMessage = ""
                                await reloadLocalChanges()
                            }
                        }
                    } label: {
                        Label("Commit & Push", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColorTokens.accent)
                    .disabled(isBusy || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    DisclosureGroup(
                        "Advanced Controls",
                        isExpanded: $isAdvancedExpanded
                    ) {
                        if localChanges.isEmpty {
                            Text("No local changes detected.")
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, AppSpacingTokens.xSmall)
                        } else {
                            VStack(spacing: AppSpacingTokens.xSmall) {
                                HStack(spacing: AppSpacingTokens.small) {
                                    Text("Changed Files (\(localChanges.count))")
                                        .font(AppTypography.caption.weight(.semibold))
                                    Spacer()
                                    if !selectedChangePaths.isEmpty {
                                        Text("\(selectedChangePaths.count) selected")
                                            .font(AppTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                ForEach(localChanges) { change in
                                    Button {
                                        toggleSelection(path: change.path)
                                    } label: {
                                        HStack(spacing: AppSpacingTokens.small) {
                                            Image(systemName: selectedChangePaths.contains(change.path) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(
                                                    selectedChangePaths.contains(change.path)
                                                        ? AppColorTokens.accent
                                                        : .secondary
                                                )

                                            Text(change.path)
                                                .font(AppTypography.captionMonospaced)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .foregroundStyle(.primary)

                                            Spacer(minLength: 8)

                                            Text(change.stageState.rawValue.capitalized)
                                                .font(AppTypography.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }

                                HStack {
                                    Button("Add Selected") {
                                        Task {
                                            let success = await viewModel.stage(repo: repo, paths: Array(selectedChangePaths))
                                            if success {
                                                await reloadLocalChanges()
                                            }
                                        }
                                    }
                                    .disabled(isBusy || selectedChangePaths.isEmpty)

                                    Button("Add All") {
                                        Task {
                                            let success = await viewModel.stageAll(repo: repo)
                                            if success {
                                                await reloadLocalChanges()
                                            }
                                        }
                                    }
                                    .disabled(isBusy || localChanges.isEmpty)
                                }
                            }
                        }

                        TextEditor(text: $advancedCommitMessage)
                            .frame(minHeight: 84)
                            .font(AppTypography.body)
                            .padding(.top, AppSpacingTokens.small)

                        HStack {
                            Button("Commit Only") {
                                Task {
                                    guard await ensureIdentityReady() else {
                                        return
                                    }
                                    let success = await viewModel.commit(repo: repo, message: advancedCommitMessage)
                                    if success {
                                        advancedCommitMessage = ""
                                        await reloadLocalChanges()
                                    }
                                }
                            }
                            .disabled(isBusy || advancedCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("Push Only") {
                                Task {
                                    _ = await viewModel.push(repo: repo)
                                    await reloadLocalChanges()
                                }
                            }
                            .disabled(isBusy)
                        }

                        Button("Discard Local Changes", role: .destructive) {
                            isShowingDiscardConfirmation = true
                        }
                        .disabled(isBusy)

                        Button("Reset to Remote", role: .destructive) {
                            isShowingResetConfirmation = true
                        }
                        .disabled(isBusy)
                    }
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
            .confirmationDialog(
                "Discard Local Changes?",
                isPresented: $isShowingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    Task {
                        await viewModel.discardLocalChanges(repo: repo)
                        await reloadLocalChanges()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove all uncommitted changes and untracked files in \(repo.displayName).")
            }
            .confirmationDialog(
                "Reset to Remote?",
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    Task {
                        await viewModel.resetToRemote(repo: repo)
                        await reloadLocalChanges()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will hard reset local history to \(repo.trackedBranch) on origin.")
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
            isEditingIdentity = false
        } else {
            isIdentityMissing = true
            isEditingIdentity = true
        }
    }

    private func reloadLocalChanges() async {
        localChanges = await viewModel.loadLocalChanges(repo: repo)
        selectedChangePaths = selectedChangePaths.intersection(Set(localChanges.map(\.path)))
    }

    private func ensureIdentityReady() async -> Bool {
        if isEditingIdentity || isIdentityMissing {
            return await saveIdentityIfValid()
        }
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
            isEditingIdentity = false
        }
        return saved
    }

    private func toggleSelection(path: String) {
        if selectedChangePaths.contains(path) {
            selectedChangePaths.remove(path)
        } else {
            selectedChangePaths.insert(path)
        }
    }
}
