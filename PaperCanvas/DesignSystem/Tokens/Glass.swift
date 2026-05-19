import SwiftUI

struct ChromeGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = Spacing.s, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func chromeGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(in: .capsule)
        } else {
            background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.Rule.hairline, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func chromeGlassRect(cornerRadius: CGFloat = Radius.xl) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.Rule.hairline, lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    func chromeInteractiveGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            chromeGlassCapsule()
        }
    }

    @ViewBuilder
    func chromeInteractiveGlassRect(cornerRadius: CGFloat = Radius.xl) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            chromeGlassRect(cornerRadius: cornerRadius)
        }
    }

    @ViewBuilder
    func chromeGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.Rule.hairline, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func chromeGlassTinted(_ color: Color, in shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(color), in: shape)
        } else {
            background(color.opacity(0.12), in: shape)
                .overlay(shape.stroke(color.opacity(0.22), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func chromeGlassButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            buttonStyle(.plain)
        }
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
