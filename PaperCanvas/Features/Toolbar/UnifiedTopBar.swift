import SwiftUI

struct UnifiedTopBar: View {
    let title: String
    let palette: PaletteState
    let onLibraryTap: () -> Void

    var pageIndex: Int = 0
    var totalPages: Int = 0
    var saveStatus: SaveStatus = .idle
    var canvasZoom: CGFloat = 1.0
    var onPageJumpTap: () -> Void = {}
    var onPreviousPage: () -> Void = {}
    var onNextPage: () -> Void = {}
    var onZoomReset: () -> Void = {}

    var debugActions: DebugActions?
    @Binding var autoHideTopBar: Bool

    struct DebugActions {
        let addTextScrap: () -> Void
        let addImageScrap: () -> Void
    }

    init(title: String,
         palette: PaletteState,
         onLibraryTap: @escaping () -> Void,
         pageIndex: Int = 0,
         totalPages: Int = 0,
         saveStatus: SaveStatus = .idle,
         canvasZoom: CGFloat = 1.0,
         onPageJumpTap: @escaping () -> Void = {},
         onPreviousPage: @escaping () -> Void = {},
         onNextPage: @escaping () -> Void = {},
         onZoomReset: @escaping () -> Void = {},
         debugActions: DebugActions? = nil,
         autoHideTopBar: Binding<Bool> = .constant(false)) {
        self.title = title
        self.palette = palette
        self.onLibraryTap = onLibraryTap
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.saveStatus = saveStatus
        self.canvasZoom = canvasZoom
        self.onPageJumpTap = onPageJumpTap
        self.onPreviousPage = onPreviousPage
        self.onNextPage = onNextPage
        self.onZoomReset = onZoomReset
        self.debugActions = debugActions
        self._autoHideTopBar = autoHideTopBar
    }

    private var hasPDF: Bool { totalPages > 0 }

    private var activeSurface: ActiveCanvasBadge.Surface {
        palette.lastActiveCanvas == .pdfInk ? .pdf : .canvas
    }

    private var rightZoneContext: ContextRightZone.Context {
        switch palette.lastActiveCanvas {
        case .pdfInk:
            return .pdf(currentPageIndex: pageIndex, totalPages: max(totalPages, 1))
        case .main:
            return .canvas(zoomScale: canvasZoom)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let density = TopBarDensity.density(forAvailableWidth: geo.size.width)
            GlassEffectContainer(spacing: TopBarMetrics.zoneSpacing) {
                HStack(spacing: TopBarMetrics.zoneSpacing) {
                    leadingZone(density: density)
                    toolZone(density: density)
                    trailingZone(density: density)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: TopBarMetrics.barHeight)
    }

    @ViewBuilder
    private func leadingZone(density: TopBarDensity) -> some View {
        HStack(spacing: TopBarMetrics.interButtonSpacing) {
            Button(action: onLibraryTap) {
                Image(systemName: "books.vertical")
                    .font(AppType.toolGlyph)
                    .frame(width: TopBarMetrics.buttonSize,
                           height: TopBarMetrics.buttonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("라이브러리")

            if density.showsTitle {
                Text(title)
                    .font(AppType.bodyEmphasized)
                    .foregroundStyle(Color.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: density.titleMaxWidth, alignment: .leading)
            }

            if hasPDF, density != .minimal {
                PageIndicator(
                    currentIndex: pageIndex,
                    totalPages: totalPages,
                    onTap: onPageJumpTap
                )
            }

            if density != .minimal {
                ActiveCanvasBadge(surface: activeSurface, isActive: true)
            }

            StatusDot(status: saveStatus, diameter: 8)
                .padding(.trailing, Spacing.xs)
        }
        .padding(.leading, density.showsTitle ? Spacing.xs : 0)
        .padding(.trailing, Spacing.xs)
        .frame(minHeight: TopBarMetrics.titleMinHeight)
        .chromeGlassCapsule()
        .layoutPriority(2)
    }

    @ViewBuilder
    private func toolZone(density: TopBarDensity) -> some View {
        Group {
            if density.allowsHorizontalScroll {
                ScrollView(.horizontal, showsIndicators: false) {
                    PaletteToolbar(palette: palette)
                        .padding(.vertical, Spacing.xs)
                }
            } else {
                PaletteToolbar(palette: palette)
                    .padding(.vertical, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .chromeGlassRect(cornerRadius: Radius.xl)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func trailingZone(density: TopBarDensity) -> some View {
        HStack(spacing: TopBarMetrics.interButtonSpacing) {
            if density.showsRightZoneContext {
                ContextRightZone(
                    context: rightZoneContext,
                    onPreviousPage: onPreviousPage,
                    onNextPage: onNextPage,
                    onZoomReset: onZoomReset
                )
                .animation(Motion.indirectFast, value: rightZoneContext)
            }

            Menu {
                Section("표시") {
                    Toggle("그리는 동안 상단바 숨김", isOn: $autoHideTopBar)
                }
                if let debugActions {
                    Section("디버그") {
                        Button("텍스트 스크랩 추가", action: debugActions.addTextScrap)
                        Button("이미지 스크랩 추가", action: debugActions.addImageScrap)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(AppType.toolGlyph)
                    .frame(width: TopBarMetrics.buttonSize,
                           height: TopBarMetrics.buttonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("설정")
        }
    }
}
