import Core
import SwiftUI
import UIKit

struct SSHKeysManagementView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel

    @State private var pendingDelete: SSHKeyRecord?
    @State private var copiedKeyID: UUID?

    var body: some View {
        List {
            if groupedKeys.isEmpty {
                AppEmptyState(
                    title: "No SSH Keys",
                    systemImage: "key.horizontal",
                    description: "Generate or import a key by adding a repository."
                )
            } else {
                ForEach(groupedKeys, id: \.host) { group in
                    Section(group.host) {
                        ForEach(group.keys) { key in
                            VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(key.label)
                                        .font(AppTypography.headline)
                                    Spacer()
                                    if viewModel.defaultKeyID(for: key.host) == key.id {
                                        Text("Default")
                                            .font(AppTypography.caption.weight(.semibold))
                                            .padding(.horizontal, AppSpacingTokens.small)
                                            .padding(.vertical, 2)
                                            .background(AppColorTokens.success.opacity(0.15))
                                            .foregroundStyle(AppColorTokens.success)
                                            .clipShape(Capsule())
                                    }
                                }

                                Text("\(key.algorithm) • \(key.keySource)")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(.secondary)

                                Text(key.publicKeyOpenSSH)
                                    .font(AppTypography.captionMonospaced)
                                    .textSelection(.enabled)
                                    .lineLimit(3)

                                HStack(spacing: AppSpacingTokens.small) {
                                    Button("Copy") {
                                        UIPasteboard.general.string = key.publicKeyOpenSSH
                                        copiedKeyID = key.id
                                    }
                                    .buttonStyle(.bordered)

                                    ShareLink(item: key.publicKeyOpenSSH) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .buttonStyle(.bordered)

                                    if viewModel.defaultKeyID(for: key.host) != key.id {
                                        Button("Set Default") {
                                            viewModel.setDefaultKey(host: key.host, keyID: key.id)
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }

                                    if copiedKeyID == key.id {
                                        Text("Copied")
                                            .font(AppTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button(role: .destructive) {
                                        pendingDelete = key
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, AppSpacingTokens.xSmall)
                        }
                    }
                }
            }
        }
        .navigationTitle("SSH Keys")
        .confirmationDialog(
            "Delete SSH Key?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { key in
            Button("Delete", role: .destructive) {
                viewModel.deleteKey(key)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { key in
            Text("This removes key \(key.label) from GitPhone and deletes its local keychain material.")
        }
    }

    private var groupedKeys: [KeyGroup] {
        Dictionary(grouping: viewModel.keys, by: { $0.host })
            .map { host, keys in
                KeyGroup(
                    host: host,
                    keys: keys.sorted {
                        $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
            }
    }
}

private struct KeyGroup {
    let host: String
    let keys: [SSHKeyRecord]
}
