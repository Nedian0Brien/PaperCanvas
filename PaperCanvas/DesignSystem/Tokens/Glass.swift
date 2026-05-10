import SwiftUI

extension View {
    func chromeGlassCapsule() -> some View {
        glassEffect(in: .capsule)
    }

    func chromeGlassRect(cornerRadius: CGFloat = Radius.xl) -> some View {
        glassEffect(in: .rect(cornerRadius: cornerRadius))
    }

    func chromeGlassCircle() -> some View {
        glassEffect(in: .circle)
    }

    func chromeGlassTinted(_ color: Color, in shape: some Shape = Capsule()) -> some View {
        glassEffect(.regular.tint(color), in: shape)
    }
}

struct GlassChip<Content: View>: View {
    let content: Content
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat

    init(horizontalPadding: CGFloat = Spacing.m,
         verticalPadding: CGFloat = Spacing.s,
         @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .chromeGlassCapsule()
    }
}
