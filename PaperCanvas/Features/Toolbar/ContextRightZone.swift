import SwiftUI

struct ContextRightZone: View {
    enum Context: Equatable {
        case pdf(currentPageIndex: Int, totalPages: Int)
        case canvas(zoomScale: CGFloat)
    }

    let context: Context
    var onPreviousPage: (() -> Void)? = nil
    var onNextPage: (() -> Void)? = nil
    var onZoomReset: (() -> Void)? = nil

    var body: some View {
        Group {
            switch context {
            case .pdf(let current, let total):
                pdfControls(current: current, total: total)
            case .canvas(let zoom):
                canvasControls(zoom: zoom)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: TopBarMetrics.titleMinHeight)
        .chromeGlassCapsule()
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func pdfControls(current: Int, total: Int) -> some View {
        HStack(spacing: TopBarMetrics.interButtonSpacing) {
            Button {
                onPreviousPage?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(current <= 0)
            .accessibilityLabel("이전 페이지")

            Button {
                onNextPage?()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(current >= total - 1)
            .accessibilityLabel("다음 페이지")
        }
        .foregroundStyle(Color.Ink.primary)
    }

    @ViewBuilder
    private func canvasControls(zoom: CGFloat) -> some View {
        Button {
            onZoomReset?()
        } label: {
            Text("\(Int((zoom * 100).rounded()))%")
                .font(AppType.monoCaption)
                .foregroundStyle(Color.Ink.secondary)
                .monospacedDigit()
                .frame(minWidth: 44)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("줌 \(Int((zoom * 100).rounded()))%, 탭하여 1:1 복귀")
    }
}
