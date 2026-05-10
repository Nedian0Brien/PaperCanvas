import SwiftUI
import PDFKit

struct PageJumpSheet: View {
    let pdfDocument: PDFDocument
    let currentPageIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: Spacing.l)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Spacing.l) {
                    ForEach(0..<pdfDocument.pageCount, id: \.self) { index in
                        Button {
                            onSelect(index)
                            dismiss()
                        } label: {
                            PageThumbnail(
                                page: pdfDocument.page(at: index),
                                index: index,
                                isCurrent: index == currentPageIndex
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.l)
            }
            .navigationTitle("페이지 점프")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

private struct PageThumbnail: View {
    let page: PDFPage?
    let index: Int
    let isCurrent: Bool

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                Color.Surface.fill
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.m)
                    .stroke(
                        isCurrent ? Color.AccentTokens.primary : Color.Rule.hairline,
                        lineWidth: isCurrent ? 2 : 0.6
                    )
            )

            Text("\(index + 1)")
                .font(AppType.monoCaption)
                .foregroundStyle(isCurrent ? Color.AccentTokens.primary : Color.Ink.secondary)
                .monospacedDigit()
        }
        .task(id: index) {
            await renderThumbnail()
        }
    }

    private func renderThumbnail() async {
        guard let page else { return }
        let pageBounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 200 / max(pageBounds.width, 1)
        let targetSize = CGSize(
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )
        let thumbnail = await Task.detached(priority: .userInitiated) { () -> UIImage in
            page.thumbnail(of: targetSize, for: .mediaBox)
        }.value
        await MainActor.run {
            self.image = thumbnail
        }
    }
}
