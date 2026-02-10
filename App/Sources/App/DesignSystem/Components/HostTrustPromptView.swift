import SwiftUI

struct HostTrustPromptView: View {
    let request: HostTrustPrompter.PendingRequest
    let onReject: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacingTokens.medium) {
            Text("Trust SSH Host")
                .font(AppTypography.headline)

            VStack(alignment: .leading, spacing: AppSpacingTokens.small) {
                Text("Host: \(request.host)")
                Text("Algorithm: \(request.algorithm)")
            }
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: AppSpacingTokens.xSmall) {
                Text("Fingerprint")
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(request.fingerprint)
                    .font(AppTypography.captionMonospaced)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Reject", role: .destructive, action: onReject)
                Spacer()
                Button("Trust & Pin", action: onApprove)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacingTokens.large)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, AppSpacingTokens.large)
        .accessibilityElement(children: .contain)
    }
}
