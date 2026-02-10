import SwiftUI

struct PublicKeysView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: SecurityCenterViewModel

    var body: some View {
        NavigationStack {
            SSHKeysManagementView(viewModel: viewModel)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
