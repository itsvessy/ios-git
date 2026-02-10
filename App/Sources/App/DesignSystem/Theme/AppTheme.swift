import SwiftUI

struct AppTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(AppColorTokens.accent)
    }
}

extension View {
    func appTheme() -> some View {
        modifier(AppTheme())
    }
}
