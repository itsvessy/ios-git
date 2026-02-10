import Core
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AddRepoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @ObservedObject var viewModel: RepoListViewModel

    @State private var displayName = ""
    @State private var remoteURL = ""
    @State private var trackedBranch = "main"
    @State private var autoSyncEnabled = true
    @State private var passphrase = ""
    @State private var selectedCloneRootURL: URL?
    @State private var selectedCloneRootBookmark: Data?
    @State private var isPresentingFolderPicker = false
    @State private var isShowingAdvanced = false
    @State private var submitError: String?
    @State private var prepared: RepoSSHPreparation?
    @State private var didConfirmKeyRegistration = false
    @State private var isPreparingSSH = false
    @State private var preparationError: String?

    var body: some View {
        Form {
            Section("Repository") {
                TextField("SSH Remote URL", text: $remoteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("add-remote-url")

                if let remoteValidationError {
                    Text(remoteValidationError)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColorTokens.error)
                }

                TextField("Tracked Branch", text: $trackedBranch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("add-tracked-branch")

                TextField("Display Name (optional)", text: $displayName)

                LabeledContent("Preview") {
                    Text(normalizedName)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Advanced Options", isExpanded: $isShowingAdvanced) {
                    Toggle("Enable Auto-Sync", isOn: $autoSyncEnabled)
                        .padding(.top, AppSpacingTokens.small)

                    cloneLocationContent
                        .padding(.top, AppSpacingTokens.small)

                    SecureField("Optional key passphrase (new keys only)", text: $passphrase)
                        .padding(.top, AppSpacingTokens.small)
                }
            }

            Section("Step 1: Prepare SSH Access") {
                if let reason = prepareDisabledReason {
                    Text(reason)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }

                if let preparationError {
                    Text(preparationError)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColorTokens.error)
                }

                Button {
                    Task { await prepareSSHAccess() }
                } label: {
                    if isPreparingSSH {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text("Prepare SSH Access")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .disabled(prepareDisabledReason != nil || isPreparingSSH)
                .accessibilityIdentifier("prepare-ssh-button")
            }

            if let prepared {
                Section("Step 2: Register SSH Key") {
                    VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
                        Text("Host: \(prepared.host)")
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)

                        Text(prepared.didGenerateKey
                            ? "New key generated for this host."
                            : "Using existing default key for this host.")
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)

                        Text(prepared.key.publicKeyOpenSSH)
                            .font(AppTypography.captionMonospaced)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: AppSpacingTokens.small) {
                        Button("Copy Public Key") {
                            UIPasteboard.general.string = prepared.key.publicKeyOpenSSH
                        }
                        .buttonStyle(.bordered)

                        if isGitHubHost {
                            Button("Open GitHub SSH Keys") {
                                guard let url = URL(string: "https://github.com/settings/keys") else {
                                    return
                                }
                                openURL(url)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text(isGitHubHost
                        ? "Add this public key to your GitHub account before cloning."
                        : "Add this public key to your Git host account before cloning.")
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        isOn: $didConfirmKeyRegistration,
                        label: {
                            Text(isGitHubHost
                                ? "I added this key to GitHub."
                                : "I added this key to my Git host.")
                        }
                    )
                }
            }

            Section("Step 3: Clone") {
                if let reason = cloneDisabledReason {
                    Text(reason)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }

                if let submitError {
                    Text(submitError)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColorTokens.error)
                }

                Text("Background sync is best-effort and iOS may delay or skip runs.")
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add Repository")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Clone") {
                    Task {
                        submitError = nil
                        guard let prepared else {
                            submitError = "Prepare SSH access before cloning."
                            return
                        }

                        let success = await viewModel.addRepo(
                            displayName: normalizedName,
                            remoteURL: prepared.normalizedRemoteURL,
                            trackedBranch: trackedBranch,
                            autoSyncEnabled: autoSyncEnabled,
                            cloneRootURL: selectedCloneRootURL,
                            cloneRootBookmark: selectedCloneRootBookmark
                        )
                        if success {
                            dismiss()
                        } else {
                            submitError = "Clone failed. Review the latest banner for details."
                        }
                    }
                }
                .disabled(cloneDisabledReason != nil || viewModel.isAddingRepo)
                .accessibilityIdentifier("clone-button")
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
        .onChange(of: remoteURL) { _, _ in
            invalidatePreparedState()
        }
        .onChange(of: trackedBranch) { _, _ in
            invalidatePreparedState()
        }
        .onChange(of: displayName) { _, _ in
            invalidatePreparedState()
        }
        .onChange(of: selectedCloneRootURL) { _, _ in
            invalidatePreparedState()
        }
    }

    @ViewBuilder
    private var cloneLocationContent: some View {
        VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
            if let selectedCloneRootURL {
                Text(selectedCloneRootURL.path)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else {
                Text("Default: GitPhone Documents/Repositories")
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Choose Folder in Files") {
                    isPresentingFolderPicker = true
                }
                if selectedCloneRootURL != nil {
                    Button("Use Default Location") {
                        selectedCloneRootURL = nil
                        selectedCloneRootBookmark = nil
                        invalidatePreparedState()
                    }
                }
            }
        }
    }

    private var prepareDisabledReason: String? {
        if viewModel.isAddingRepo {
            return "Clone is already in progress."
        }

        if isPreparingSSH {
            return "SSH preparation is already in progress."
        }

        if remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a remote SSH URL."
        }

        if let remoteValidationError {
            return remoteValidationError
        }

        if trackedBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a tracked branch."
        }

        if normalizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a display name or valid remote URL."
        }

        return nil
    }

    private var cloneDisabledReason: String? {
        if viewModel.isAddingRepo {
            return "Clone is already in progress."
        }

        if let prepareDisabledReason {
            return prepareDisabledReason
        }

        guard prepared != nil else {
            return "Prepare SSH access before cloning."
        }

        guard didConfirmKeyRegistration else {
            return isGitHubHost
                ? "Confirm that you added the key to GitHub."
                : "Confirm that you added the key to your Git host."
        }

        return nil
    }

    private var remoteValidationError: String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        do {
            _ = try SSHRemoteURL(parse: trimmed)
            return nil
        } catch {
            return error.localizedDescription
        }
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

    private var isGitHubHost: Bool {
        guard let host = prepared?.host.lowercased() else {
            return false
        }
        return host == "github.com" || host == "ssh.github.com"
    }

    private func prepareSSHAccess() async {
        preparationError = nil
        submitError = nil
        isPreparingSSH = true
        defer { isPreparingSSH = false }

        do {
            prepared = try await viewModel.prepareSSHForAddRepo(
                remoteURL: remoteURL,
                passphrase: passphrase.nonEmpty
            )
            didConfirmKeyRegistration = false
        } catch {
            prepared = nil
            didConfirmKeyRegistration = false
            preparationError = error.localizedDescription
        }
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
            invalidatePreparedState()
        } catch {
            submitError = "Could not save folder access: \(error.localizedDescription)"
            selectedCloneRootURL = nil
            selectedCloneRootBookmark = nil
            invalidatePreparedState()
        }
    }

    private func invalidatePreparedState() {
        prepared = nil
        didConfirmKeyRegistration = false
        preparationError = nil
        submitError = nil
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
