import SwiftUI

enum ScrapVisualState: Equatable {
    case normal
    case selected
    case dragging
    case editing
}

struct ScrapCardContent: View {
    let kind: ScrapKind
    let anchorKind: PDFAnchorKind?
    let text: String?
    let image: UIImage?
    let documentTitle: String?
    let pageIndex: Int
    var state: ScrapVisualState = .normal
    var zoom: CGFloat = 1.0

    private var tint: Color {
        Color.ScrapKindTint.color(kind: kind, anchor: anchorKind)
    }

    private var icon: String {
        Color.ScrapKindTint.icon(kind: kind, anchor: anchorKind)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            body(for: kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            sourceChip
                .padding(.trailing, Spacing.s)
                .padding(.bottom, Spacing.s)
                .opacity(zoom < 0.6 ? 0 : 1)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fallback opaque-ish paper backing so the card always reads on the
        // canvas, even if the Liquid Glass material fails to render (e.g. in
        // a detached hosting context, low-power mode, or a destination
        // without the necessary backdrop).
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(Color.Surface.paper.opacity(0.92))
        )
        .chromeGlassTinted(tint, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(borderOverlay)
        .shadow(
            color: .black.opacity(state == .dragging ? 0.20 : 0.06),
            radius: state == .dragging ? 16 : 6,
            x: 0,
            y: state == .dragging ? 10 : 2
        )
        .animation(Motion.indirectFast, value: state)
    }

    @ViewBuilder
    private func body(for kind: ScrapKind) -> some View {
        switch kind {
        case .text:
            Text(text ?? "")
                .font(.body)
                .foregroundStyle(Color.Ink.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .padding(.bottom, 32)
                .redacted(reason: zoom < 0.35 ? .placeholder : [])
        case .image:
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Spacing.xs)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var sourceChip: some View {
        GlassChip(horizontalPadding: Spacing.s, verticalPadding: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                Text(documentTitle ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· p.\(pageIndex + 1)")
                    .foregroundStyle(Color.Ink.secondary)
            }
            .font(.caption2)
            .foregroundStyle(Color.Ink.primary)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
        switch state {
        case .normal:
            shape.stroke(Color.clear, lineWidth: 0)
        case .selected, .dragging:
            shape.stroke(Color.accentColor, lineWidth: 1)
        case .editing:
            shape.stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }
    }
}
