import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel

    var body: some View {
        List {
            Section("Log File") {
                if let logURL = viewModel.logFileURL {
                    Text(logURL.path)
                        .font(AppTypography.captionMonospaced)
                        .textSelection(.enabled)
                        .lineLimit(3)

                    if FileManager.default.fileExists(atPath: logURL.path) {
                        ShareLink(item: logURL) {
                            Label("Share Log", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Text("No log file currently exists.")
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Log path unavailable.")
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task {
                        await viewModel.clearLogs()
                    }
                } label: {
                    Label("Clear Log", systemImage: "trash")
                }

                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
