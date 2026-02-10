import SwiftUI

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppSpacingTokens.medium)
            .background(AppColorTokens.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
