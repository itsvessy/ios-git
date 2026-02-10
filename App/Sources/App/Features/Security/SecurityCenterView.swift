import SwiftUI

struct SecurityCenterView: View {
    @ObservedObject var viewModel: SecurityCenterViewModel

    var body: some View {
        List {
            Section("App Lock") {
                Picker("Relock", selection: Binding(
                    get: { viewModel.selectedRelockInterval },
                    set: { newValue in
                        viewModel.setRelockInterval(newValue)
                    }
                )) {
                    ForEach(viewModel.relockIntervalOptions, id: \.self) { interval in
                        Text(intervalLabel(interval)).tag(interval)
                    }
                }

                Button("Lock Now", role: .destructive) {
                    viewModel.lockNow()
                }
            }

            Section("Security Data") {
                NavigationLink {
                    SSHKeysManagementView(viewModel: viewModel)
                } label: {
                    LabeledContent("SSH Keys") {
                        Text("\(viewModel.keys.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    TrustedHostsView(viewModel: viewModel)
                } label: {
                    LabeledContent("Trusted Hosts") {
                        Text("\(viewModel.fingerprints.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    DiagnosticsView(viewModel: viewModel)
                } label: {
                    Text("Diagnostics")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Security Center")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            viewModel.refresh()
        }
    }

    private func intervalLabel(_ interval: TimeInterval) -> String {
        switch Int(interval) {
        case 60:
            return "1 minute"
        case 300:
            return "5 minutes"
        case 900:
            return "15 minutes"
        case 1800:
            return "30 minutes"
        case 3600:
            return "60 minutes"
        default:
            return "\(Int(interval / 60)) minutes"
        }
    }
}
