import Core
import Foundation
import SwiftUI

struct RepoFilesView: View {
    let repo: RepoRecord
    @ObservedObject var viewModel: RepoListViewModel

    @State private var entries: [WorkingTreeEntry] = []
    @State private var localChanges: [RepoLocalChange] = []
    @State private var selectedChangePaths: Set<String> = []
    @State private var errorMessage: String?
    @State private var showHiddenItems = false
    @State private var includeDirectories = false
    @State private var searchQuery = ""
    @State private var commitMessage = ""
    @State private var identityName = ""
    @State private var identityEmail = ""
    @State private var isIdentityMissing = true
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("Repository Root") {
                Text(repo.localPath)
                    .font(AppTypography.captionMonospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            changedFilesSection

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColorTokens.error)
                }
            } else if visibleEntries.isEmpty {
                Section {
                    AppEmptyState(
                        title: entries.isEmpty ? "No Files" : "No Matches",
                        systemImage: "doc",
                        description: entries.isEmpty
                            ? "No visible files were found with current filters."
                            : "Try a different search query."
                    )
                }
            } else {
                Section("\(includeDirectories ? "Working Tree" : "Files") (\(visibleEntries.count))") {
                    ForEach(visibleEntries) { entry in
                        HStack(spacing: AppSpacingTokens.medium) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.isDirectory ? AppColorTokens.accent : .secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.relativePath)
                                    .font(AppTypography.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if let bytes = entry.fileSize {
                                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        .font(AppTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if !entry.isDirectory {
                                ShareLink(item: entry.url) {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(repo.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchQuery, prompt: "Search files")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show Hidden Items", isOn: $showHiddenItems)
                    Toggle("Include Folders", isOn: $includeDirectories)
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scheduleLoadEntries()
                    Task { await reloadGitState() }
                } label: {
                    Label("Refresh Files", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            scheduleLoadEntries()
            await reloadGitState()
        }
        .onChange(of: showHiddenItems) { _, _ in
            scheduleLoadEntries()
        }
        .onChange(of: includeDirectories) { _, _ in
            scheduleLoadEntries()
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    @ViewBuilder
    private var changedFilesSection: some View {
        Section("Changed Files (\(localChanges.count))") {
            if localChanges.isEmpty {
                Text("No changed files.")
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            } else {
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
            }

            HStack {
                Button("Add Selected") {
                    Task {
                        let success = await viewModel.stage(repo: repo, paths: Array(selectedChangePaths))
                        if success {
                            await reloadGitState()
                        }
                    }
                }
                .disabled(isBusy || selectedChangePaths.isEmpty)

                Button("Add All") {
                    Task {
                        let success = await viewModel.stageAll(repo: repo)
                        if success {
                            await reloadGitState()
                        }
                    }
                }
                .disabled(isBusy || localChanges.isEmpty)
            }

            if isIdentityMissing {
                TextField("Commit Name", text: $identityName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()

                TextField("Commit Email", text: $identityEmail)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)

                Button("Save Identity") {
                    Task {
                        _ = await saveIdentityIfValid()
                    }
                }
                .disabled(
                    isBusy ||
                        identityName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        identityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            TextEditor(text: $commitMessage)
                .frame(minHeight: 90)
                .font(AppTypography.body)

            HStack {
                Button("Commit") {
                    Task {
                        guard await ensureIdentityReady() else {
                            return
                        }
                        let success = await viewModel.commit(repo: repo, message: commitMessage)
                        if success {
                            commitMessage = ""
                            await reloadGitState()
                        }
                    }
                }
                .disabled(isBusy || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Push") {
                    Task {
                        _ = await viewModel.push(repo: repo)
                        await reloadGitState()
                    }
                }
                .disabled(isBusy)
            }
        }
    }

    private var visibleEntries: [WorkingTreeEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return entries
        }

        return entries.filter { entry in
            entry.relativePath.lowercased().contains(query)
        }
    }

    private func scheduleLoadEntries() {
        loadTask?.cancel()

        let currentRepo = repo
        let includeHidden = showHiddenItems
        let includeFolders = includeDirectories

        loadTask = Task {
            await loadEntries(
                repo: currentRepo,
                showHiddenItems: includeHidden,
                includeDirectories: includeFolders
            )
        }
    }

    private func loadEntries(repo: RepoRecord, showHiddenItems: Bool, includeDirectories: Bool) async {
        let result = await RepoFilesLoader.shared.load(
            repo: repo,
            showHiddenItems: showHiddenItems,
            includeDirectories: includeDirectories
        )

        guard !Task.isCancelled else {
            return
        }

        switch result {
        case let .success(loadedEntries):
            errorMessage = nil
            entries = loadedEntries
        case let .failure(message):
            entries = []
            errorMessage = message
        case .cancelled:
            break
        }
    }

    private var isBusy: Bool {
        viewModel.isGitActionInProgress(repoID: repo.id) || viewModel.isSyncing(repoID: repo.id)
    }

    private func reloadGitState() async {
        localChanges = await viewModel.loadLocalChanges(repo: repo)
        selectedChangePaths = selectedChangePaths.intersection(Set(localChanges.map(\.path)))

        let identity = await viewModel.loadCommitIdentity(repo: repo)
        if let identity {
            identityName = identity.name
            identityEmail = identity.email
            isIdentityMissing = false
        } else {
            isIdentityMissing = true
        }
    }

    private func toggleSelection(path: String) {
        if selectedChangePaths.contains(path) {
            selectedChangePaths.remove(path)
        } else {
            selectedChangePaths.insert(path)
        }
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

private struct WorkingTreeEntry: Identifiable, Sendable {
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let fileSize: Int64?

    var id: String { relativePath }
}

private struct ScopedRoot: Sendable {
    let url: URL
    let didStartSecurityScope: Bool
}

private enum RepoFilesLoadResult: Sendable {
    case success([WorkingTreeEntry])
    case failure(String)
    case cancelled
}

private actor RepoFilesLoader {
    static let shared = RepoFilesLoader()

    private let fileManager = FileManager.default

    func load(
        repo: RepoRecord,
        showHiddenItems: Bool,
        includeDirectories: Bool
    ) -> RepoFilesLoadResult {
        if Task.isCancelled {
            return .cancelled
        }

        let scopedRoot: ScopedRoot
        do {
            scopedRoot = try resolveScopedRoot(for: repo)
        } catch {
            return .failure(error.localizedDescription)
        }
        defer {
            if scopedRoot.didStartSecurityScope {
                scopedRoot.url.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: scopedRoot.url.path) else {
            return .failure("Repository folder does not exist at \(scopedRoot.url.path).")
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenItems {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: scopedRoot.url,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            return .failure("Unable to enumerate repository files.")
        }

        var loaded: [WorkingTreeEntry] = []
        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                return .cancelled
            }

            let relativePath = item.path.replacingOccurrences(of: scopedRoot.url.path + "/", with: "")
            if relativePath.isEmpty || relativePath == "." {
                continue
            }
            if relativePath == ".git" {
                enumerator.skipDescendants()
                continue
            }
            if relativePath.hasPrefix(".git/") {
                continue
            }

            if !showHiddenItems {
                let containsHiddenComponent = relativePath
                    .split(separator: "/")
                    .contains { $0.hasPrefix(".") }
                if containsHiddenComponent {
                    continue
                }
            }

            let values = try? item.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory ?? false
            if isDirectory && !includeDirectories {
                continue
            }

            loaded.append(
                WorkingTreeEntry(
                    relativePath: relativePath,
                    url: item,
                    isDirectory: isDirectory,
                    fileSize: values?.fileSize.map(Int64.init)
                )
            )
        }

        let sorted = loaded.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }

        return .success(sorted)
    }

    private func resolveScopedRoot(for repo: RepoRecord) throws -> ScopedRoot {
        if let bookmarkData = repo.securityScopedBookmark {
            var isStale = false
            let resolvedURL: URL
            do {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw RepoError.ioFailure("Could not resolve folder permission bookmark.")
            }
            _ = isStale

            let started = resolvedURL.startAccessingSecurityScopedResource()
            return ScopedRoot(url: resolvedURL, didStartSecurityScope: started)
        }

        return ScopedRoot(
            url: URL(fileURLWithPath: repo.localPath, isDirectory: true),
            didStartSecurityScope: false
        )
    }
}
