import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AddRepoView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: RepoListViewModel
    @ObservedObject var hostTrustPrompter: HostTrustPrompter

    @State private var displayName = ""
    @State private var remoteURL = ""
    @State private var trackedBranch = "main"
    @State private var autoSyncEnabled = true
    @State private var generateKeyIfNeeded = true
    @State private var passphrase = ""
    @State private var selectedCloneRootURL: URL?
    @State private var selectedCloneRootBookmark: Data?
    @State private var isPresentingFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    TextField("Display Name", text: $displayName)
                        .textInputAutocapitalization(.never)
                    TextField("SSH Remote URL", text: $remoteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Tracked Branch", text: $trackedBranch)
                        .textInputAutocapitalization(.never)
                    Toggle("Enable Auto-Sync", isOn: $autoSyncEnabled)
                }

                Section("Clone Location") {
                    if let selectedCloneRootURL {
                        Text(selectedCloneRootURL.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    } else {
                        Text("Default: GitPhone Documents/Repositories")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Choose Folder in Files") {
                        isPresentingFolderPicker = true
                    }

                    if selectedCloneRootURL != nil {
                        Button("Use Default Location") {
                            selectedCloneRootURL = nil
                            selectedCloneRootBookmark = nil
                        }
                    }
                }

                Section("SSH Key") {
                    Toggle("Generate host key if missing", isOn: $generateKeyIfNeeded)
                    if generateKeyIfNeeded {
                        SecureField("Optional key passphrase", text: $passphrase)
                    }
                }

                Section {
                    Text("Background sync is best-effort and iOS may delay or skip runs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Repository")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") {
                        Task {
                            await viewModel.addRepo(
                                displayName: normalizedName,
                                remoteURL: remoteURL,
                                trackedBranch: trackedBranch,
                                autoSyncEnabled: autoSyncEnabled,
                                generateKeyIfNeeded: generateKeyIfNeeded,
                                passphrase: passphrase.nonEmpty,
                                cloneRootURL: selectedCloneRootURL,
                                cloneRootBookmark: selectedCloneRootBookmark
                            )
                            if viewModel.statusMessage?.hasPrefix("Added") == true {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSubmit || viewModel.isWorking)
                }
            }
            .overlay {
                if let request = hostTrustPrompter.pendingRequest {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Trust SSH Host")
                            .font(.headline)
                        Text("Host: \(request.host)")
                            .font(.subheadline)
                        Text("Algorithm: \(request.algorithm)")
                            .font(.subheadline)
                        Text("Fingerprint:")
                            .font(.subheadline)
                        Text(request.fingerprint)
                            .font(.footnote)
                            .textSelection(.enabled)

                        HStack {
                            Button("Reject", role: .destructive) {
                                hostTrustPrompter.reject()
                            }
                            Spacer()
                            Button("Trust & Pin") {
                                hostTrustPrompter.approve()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
                }
            }
            .sheet(isPresented: $isPresentingFolderPicker) {
                FolderPicker(
                    onPick: { pickedURL in
                        cacheCloneRoot(url: pickedURL)
                        isPresentingFolderPicker = false
                    },
                    onCancel: {
                        isPresentingFolderPicker = false
                    }
                )
            }
        }
    }

    private var canSubmit: Bool {
        !normalizedName.isEmpty && !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !trackedBranch.isEmpty
    }

    private var normalizedName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return remoteURL
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".git", with: "") ?? "Repository"
    }

    private func cacheCloneRoot(url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            selectedCloneRootURL = url
            selectedCloneRootBookmark = bookmarkData
        } catch {
            viewModel.statusMessage = "Could not save folder access: \(error.localizedDescription)"
            selectedCloneRootURL = nil
            selectedCloneRootBookmark = nil
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let selected = urls.first else {
                onCancel()
                return
            }
            onPick(selected)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
