import Core
import SwiftUI

struct TrustedHostsView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel

    @State private var pendingDelete: HostFingerprintRecord?

    var body: some View {
        List {
            if viewModel.fingerprints.isEmpty {
                AppEmptyState(
                    title: "No Trusted Hosts",
                    systemImage: "lock.slash",
                    description: "Trusted host fingerprints appear after successful SSH trust decisions."
                )
            } else {
                ForEach(viewModel.fingerprints, id: \ .lookupKey) { fingerprint in
                    VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
                        HStack {
                            Text(fingerprint.host)
                                .font(AppTypography.headline)
                            Spacer()
                            Text("\(fingerprint.port)")
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(fingerprint.algorithm)
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)

                        Text(fingerprint.fingerprintSHA256)
                            .font(AppTypography.captionMonospaced)
                            .textSelection(.enabled)
                            .lineLimit(2)

                        Text("Accepted \(fingerprint.acceptedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, AppSpacingTokens.xSmall)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = fingerprint
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Trusted Hosts")
        .confirmationDialog(
            "Remove Trusted Host?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { fingerprint in
            Button("Remove", role: .destructive) {
                Task {
                    await viewModel.deleteFingerprint(fingerprint)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { fingerprint in
            Text("This host will require trust confirmation on the next SSH connection to \(fingerprint.host).")
        }
    }
}

private extension HostFingerprintRecord {
    var lookupKey: String {
        "\(host.lowercased()):\(port):\(algorithm.lowercased())"
    }
}
