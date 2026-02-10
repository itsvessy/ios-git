import Core
import Foundation
import SwiftUI

struct RepoFilesView: View {
    let repo: RepoRecord

    @State private var entries: [WorkingTreeEntry] = []
    @State private var errorMessage: String?
    @State private var showHiddenItems = false
    @State private var includeDirectories = false
    @State private var searchQuery = ""
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("Repository Root") {
                Text(repo.localPath)
                    .font(AppTypography.captionMonospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

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
                } label: {
                    Label("Refresh Files", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            scheduleLoadEntries()
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
