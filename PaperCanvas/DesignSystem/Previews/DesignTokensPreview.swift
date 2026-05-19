#if DEBUG
import SwiftUI

private struct ColorRow: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.m) {
            RoundedRectangle(cornerRadius: Radius.s)
                .fill(color)
                .frame(width: 56, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s)
                        .stroke(Color.Rule.hairline, lineWidth: 0.5)
                )
            Text(label)
                .font(AppType.body)
                .foregroundStyle(Color.Ink.primary)
            Spacer()
        }
    }
}

private struct GlassRow: View {
    let label: String
    @ViewBuilder var sample: AnyView

    var body: some View {
        HStack(spacing: Spacing.m) {
            sample
            Text(label)
                .font(AppType.callout)
                .foregroundStyle(Color.Ink.secondary)
            Spacer()
        }
    }
}

struct DesignTokensPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Group {
                    Text("Surface")
                        .font(AppType.title)
                    ColorRow(label: "paper", color: Color.Surface.paper)
                    ColorRow(label: "subtle", color: Color.Surface.subtle)
                    ColorRow(label: "fill", color: Color.Surface.fill)
                }

                Group {
                    Text("Ink")
                        .font(AppType.title)
                    ColorRow(label: "primary", color: Color.Ink.primary)
                    ColorRow(label: "secondary", color: Color.Ink.secondary)
                    ColorRow(label: "tertiary", color: Color.Ink.tertiary)
                }

                Group {
                    Text("Accent")
                        .font(AppType.title)
                    ColorRow(label: "primary", color: Color.AccentTokens.primary)
                    ColorRow(label: "tint", color: Color.AccentTokens.tint)
                }

                Group {
                    Text("Status")
                        .font(AppType.title)
                    ColorRow(label: "saving", color: Color.Status.saving)
                    ColorRow(label: "saved", color: Color.Status.saved)
                    ColorRow(label: "error", color: Color.Status.error)
                }

                Group {
                    Text("Type")
                        .font(AppType.title)
                    Text("display").font(AppType.display)
                    Text("title").font(AppType.title)
                    Text("headline").font(AppType.headline)
                    Text("body").font(AppType.body)
                    Text("bodyEmphasized").font(AppType.bodyEmphasized)
                    Text("callout").font(AppType.callout)
                    Text("caption").font(AppType.caption)
                    Text("monoCaption 12 / 47").font(AppType.monoCaption)
                }

                Group {
                    Text("Glass")
                        .font(AppType.title)
                    glassSamples
                }
            }
            .padding(Spacing.l)
        }
        .background(Color.Surface.paper)
    }

    @ViewBuilder
    private var glassSamples: some View {
        ChromeGlassContainer(spacing: Spacing.s) {
            glassSampleContent
        }
    }

    private var glassSampleContent: some View {
        HStack(spacing: Spacing.s) {
            GlassChip { Text("capsule").font(AppType.caption) }
            GlassChip(horizontalPadding: Spacing.s, verticalPadding: Spacing.xs) {
                Image(systemName: "checkmark")
            }
            Text("rect r=22")
                .font(AppType.caption)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .chromeGlassRect()
            Circle()
                .fill(Color.Status.saved)
                .frame(width: 12, height: 12)
                .padding(Spacing.xs)
                .chromeGlassCircle()
        }
    }
}

#Preview("Light") {
    DesignTokensPreview()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    DesignTokensPreview()
        .preferredColorScheme(.dark)
}
#endif
