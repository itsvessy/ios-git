import Core
import Foundation
import SwiftUI

struct RepoFilesView: View {
    let repo: RepoRecord

    @State private var entries: [WorkingTreeEntry] = []
    @State private var errorMessage: String?
    @State private var showHiddenItems = false
    @State private var includeDirectories = false

    var body: some View {
        List {
            Section {
                Text(repo.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Repository Root")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            } else if entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Files",
                        systemImage: "doc",
                        description: Text("No visible files were found with the current filters.")
                    )
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                .foregroundStyle(entry.isDirectory ? .yellow : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.relativePath)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if let bytes = entry.fileSize {
                                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                        .font(.caption)
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
                } header: {
                    Text("\(includeDirectories ? "Working Tree" : "Files") (\(entries.count))")
                }
            }
        }
        .navigationTitle(repo.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
                    loadEntries()
                } label: {
                    Label("Refresh Files", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            loadEntries()
        }
        .onChange(of: showHiddenItems) { _, _ in
            loadEntries()
        }
        .onChange(of: includeDirectories) { _, _ in
            loadEntries()
        }
    }

    private func loadEntries() {
        errorMessage = nil
        let scopedRoot: ScopedRoot

        do {
            scopedRoot = try resolveScopedRoot()
        } catch {
            entries = []
            errorMessage = error.localizedDescription
            return
        }
        defer {
            scopedRoot.stopAccess()
        }

        guard FileManager.default.fileExists(atPath: scopedRoot.url.path) else {
            entries = []
            errorMessage = "Repository folder does not exist at \(scopedRoot.url.path)."
            return
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenItems {
            options.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: scopedRoot.url,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            entries = []
            errorMessage = "Unable to enumerate repository files."
            return
        }

        var loaded: [WorkingTreeEntry] = []
        while let item = enumerator.nextObject() as? URL {
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

        entries = loaded.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func resolveScopedRoot() throws -> ScopedRoot {
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
            return ScopedRoot(url: resolvedURL) {
                if started {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
        }

        return ScopedRoot(url: URL(fileURLWithPath: repo.localPath, isDirectory: true)) {}
    }
}

private struct WorkingTreeEntry: Identifiable {
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let fileSize: Int64?

    var id: String { relativePath }
}

private struct ScopedRoot {
    let url: URL
    let stopAccess: () -> Void
}
