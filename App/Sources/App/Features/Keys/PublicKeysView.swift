import Core
import SwiftUI
import UIKit

struct PublicKeysView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RepoListViewModel

    @State private var copiedKeyID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.sshKeys.isEmpty {
                    ContentUnavailableView(
                        "No SSH Keys",
                        systemImage: "key.horizontal",
                        description: Text("Generate or import a key by adding a repository, then copy the public key into GitHub.")
                    )
                } else {
                    List(sortedKeys) { key in
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(key.label)
                                    .font(.headline)
                                Text("\(key.host) • \(key.algorithm)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(key.publicKeyOpenSSH)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)

                                HStack {
                                    Button("Copy") {
                                        UIPasteboard.general.string = key.publicKeyOpenSSH
                                        copiedKeyID = key.id
                                    }
                                    .buttonStyle(.bordered)

                                    ShareLink(item: key.publicKeyOpenSSH) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .buttonStyle(.borderedProminent)

                                    if copiedKeyID == key.id {
                                        Text("Copied")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Public Keys")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var sortedKeys: [SSHKeyRecord] {
        viewModel.sshKeys.sorted {
            if $0.host.caseInsensitiveCompare($1.host) == .orderedSame {
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
        }
    }
}
