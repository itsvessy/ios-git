import SwiftUI

struct AppBannerView: View {
    let banner: RepoBannerMessage

    var body: some View {
        HStack(spacing: AppSpacingTokens.small) {
            Image(systemName: banner.kind.symbolName)
                .foregroundStyle(AppColorTokens.tint(for: banner.kind))
            Text(banner.text)
                .font(AppTypography.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacingTokens.medium)
        .padding(.vertical, AppSpacingTokens.small)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColorTokens.tint(for: banner.kind).opacity(0.18), lineWidth: 1)
        }
        .accessibilityAddTraits(.isStaticText)
    }
}
