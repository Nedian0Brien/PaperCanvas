import SwiftUI
import SwiftData
import PDFKit
import PencilKit

struct RootSplitView: View {
    @Bindable var paper: PaperDocument

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var pdfDocument: PDFDocument?
    @State private var canvasDrawing = PKDrawing()
    @State private var pdfInkStrokes: [Int: [InkStroke]] = [:]
    @State private var contentOffset: CGPoint = .zero
    @State private var currentPageIndex: Int = 0
    @State private var navigationTarget: PDFNavigationTarget?
    @State private var canvasResetTrigger: UUID?
    @State private var leftFraction: CGFloat = 0.5
    @State private var loadError: String?
    @State private var didLoad = false
    @State private var palette = PaletteState()

    @State private var accessingURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveStatus: SaveStatus = .idle
    @State private var canvasZoomScale: CGFloat = 1.0
    @State private var showingPageJumpSheet = false
    @State private var savedStatusResetTask: Task<Void, Never>?
    @AppStorage("PaperCanvas.autoHideTopBar") private var autoHideTopBar = false

    private var chromeOpacity: Double {
        guard palette.isStrokeInProgress else { return 1.0 }
        return autoHideTopBar ? 0.0 : Motion.dimDuringStrokeOpacity
    }

    private let dividerVisualWidth: CGFloat = 8
    private let dividerHitWidth: CGFloat = 28
    private let minFraction: CGFloat = 0.2
    private let maxFraction: CGFloat = 0.8

    private var canvasBackground: CanvasBackground {
        CanvasBackground(rawValue: paper.canvasBackgroundRaw) ?? .dots
    }

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let leftWidth = max(totalWidth * minFraction,
                                min(totalWidth * maxFraction,
                                    totalWidth * leftFraction))
            let rightWidth = max(0, totalWidth - leftWidth - dividerVisualWidth)

            HStack(spacing: 0) {
                leftPane
                    .frame(width: leftWidth)

                DividerHandle(visualWidth: dividerVisualWidth,
                              hitWidth: dividerHitWidth)
                    .frame(width: dividerHitWidth)
                    .gesture(dividerDrag(totalWidth: totalWidth))

                ZStack(alignment: .topTrailing) {
                    CanvasView(drawing: $canvasDrawing,
                               contentOffset: $contentOffset,
                               resetTrigger: $canvasResetTrigger,
                               initialContentSize: CGSize(
                                   width: paper.canvasContentWidth,
                                   height: paper.canvasContentHeight),
                               scraps: sortedScraps,
                               palette: palette,
                               background: canvasBackground,
                               onScrapTap: handleScrapTap,
                               onDrop: handleCanvasDrop,
                               onScrapMoved: handleScrapMoved,
                               onScrapResized: handleScrapResized,
                               onScrapDeleted: handleScrapDeleted,
                               onZoomChanged: { scale in
                                   canvasZoomScale = scale
                               },
                               onStrokeBegan: {
                                   palette.isStrokeInProgress = true
                               },
                               onStrokeEnded: {
                                   palette.isStrokeInProgress = false
                               })

                    canvasFloatingControls
                        .padding(Spacing.m)
                        .opacity(chromeOpacity)
                        .animation(Motion.chromeFade, value: chromeOpacity)
                        .allowsHitTesting(chromeOpacity > 0.05)
                }
                .frame(width: rightWidth - (dividerHitWidth - dividerVisualWidth))
            }
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .top, spacing: 0) {
            UnifiedTopBar(
                title: paper.title,
                palette: palette,
                onLibraryTap: {
                    handleDisappear()
                    dismiss()
                },
                pageIndex: currentPageIndex,
                totalPages: pdfDocument?.pageCount ?? 0,
                saveStatus: saveStatus,
                canvasZoom: canvasZoomScale,
                onPageJumpTap: { showingPageJumpSheet = true },
                onPreviousPage: handlePreviousPage,
                onNextPage: handleNextPage,
                onZoomReset: { canvasResetTrigger = UUID() },
                debugActions: debugActions,
                autoHideTopBar: $autoHideTopBar
            )
            .padding(.horizontal, TopBarMetrics.outerHorizontalPadding)
            .padding(.top, TopBarMetrics.outerTopPadding)
            .padding(.bottom, TopBarMetrics.outerBottomPadding)
            .opacity(chromeOpacity)
            .animation(Motion.chromeFade, value: chromeOpacity)
            .allowsHitTesting(chromeOpacity > 0.05)
        }
        .sheet(isPresented: $showingPageJumpSheet) {
            if let pdfDocument {
                PageJumpSheet(
                    pdfDocument: pdfDocument,
                    currentPageIndex: currentPageIndex,
                    onSelect: { index in
                        navigationTarget = PDFNavigationTarget(pageIndex: index, pageRect: .zero)
                    }
                )
            }
        }
        .task { await loadIfNeeded() }
        .onChange(of: canvasDrawing) { _, _ in scheduleSave() }
        .onChange(of: pdfInkStrokes) { _, _ in scheduleSave() }
        .onChange(of: contentOffset) { _, _ in scheduleSave() }
        .onChange(of: currentPageIndex) { _, _ in scheduleSave() }
        .onDisappear { handleDisappear() }
    }

    private func handlePreviousPage() {
        guard currentPageIndex > 0 else { return }
        navigationTarget = PDFNavigationTarget(pageIndex: currentPageIndex - 1, pageRect: .zero)
    }

    private func handleNextPage() {
        guard let pdfDocument, currentPageIndex < pdfDocument.pageCount - 1 else { return }
        navigationTarget = PDFNavigationTarget(pageIndex: currentPageIndex + 1, pageRect: .zero)
    }

    @ViewBuilder
    private var leftPane: some View {
        if let pdfDocument {
            PDFKitView(document: pdfDocument,
                       currentPageIndex: $currentPageIndex,
                       navigationTarget: $navigationTarget,
                       pageInkStrokes: $pdfInkStrokes,
                       palette: palette,
                       onRegionCaptured: handleRegionCaptured)
        } else if let loadError {
            VStack(spacing: Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.Ink.secondary)
                Text(loadError)
                    .foregroundStyle(Color.Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Surface.subtle)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Surface.subtle)
        }
    }

    @ViewBuilder
    private var canvasFloatingControls: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            VStack(spacing: Spacing.s) {
                Button {
                    canvasResetTrigger = UUID()
                } label: {
                    Image(systemName: "scope")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("캔버스 가운데로")

                Menu {
                    ForEach(CanvasBackground.allCases) { type in
                        Button {
                            paper.canvasBackgroundRaw = type.rawValue
                            paper.updatedAt = .now
                        } label: {
                            Label(type.label, systemImage: type.systemImage)
                            if canvasBackground == type {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    Image(systemName: canvasBackground.systemImage)
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("캔버스 배경")
            }
        }
        .foregroundStyle(Color.Ink.primary)
    }

    private var debugActions: UnifiedTopBar.DebugActions? {
        #if DEBUG
        UnifiedTopBar.DebugActions(
            addTextScrap: addDummyTextScrap,
            addImageScrap: addDummyImageScrap
        )
        #else
        nil
        #endif
    }

    private var sortedScraps: [ScrapItem] {
        paper.scrapItems.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func handleScrapTap(_ id: UUID) {
        guard let scrap = paper.scrapItems.first(where: { $0.id == id }) else { return }
        let rect = CGRect(x: scrap.sourceRectX,
                          y: scrap.sourceRectY,
                          width: scrap.sourceRectW,
                          height: scrap.sourceRectH)
        navigationTarget = PDFNavigationTarget(pageIndex: scrap.sourcePageIndex,
                                               pageRect: rect)
    }

    private func handleRegionCaptured(pageIndex: Int, pageRect: CGRect, image: UIImage) {
        guard let data = image.pngData() else { return }
        let position = CGPoint(x: contentOffset.x + 80, y: contentOffset.y + 80)
        let displaySize = imageDisplaySize(for: image)
        let scrap = ScrapItem(
            kind: .image,
            imageData: data,
            position: position,
            size: displaySize,
            sourcePageIndex: pageIndex,
            sourceRect: pageRect
        )
        scrap.document = paper
        modelContext.insert(scrap)
    }

    private func imageDisplaySize(for image: UIImage) -> CGSize {
        let maxDim: CGFloat = 320
        let aspect = image.size.width / max(image.size.height, 1)
        if aspect >= 1 { return CGSize(width: maxDim, height: maxDim / aspect) }
        return CGSize(width: maxDim * aspect, height: maxDim)
    }

    private func handleScrapMoved(_ id: UUID, _ position: CGPoint) {
        guard let scrap = paper.scrapItems.first(where: { $0.id == id }) else { return }
        scrap.positionX = Double(position.x)
        scrap.positionY = Double(position.y)
        paper.updatedAt = .now
    }

    private func handleScrapResized(_ id: UUID, _ size: CGSize) {
        guard let scrap = paper.scrapItems.first(where: { $0.id == id }) else { return }
        scrap.width = Double(size.width)
        scrap.height = Double(size.height)
        paper.updatedAt = .now
    }

    private func handleScrapDeleted(_ id: UUID) {
        guard let scrap = paper.scrapItems.first(where: { $0.id == id }) else { return }
        modelContext.delete(scrap)
    }

    private func handleCanvasDrop(_ payload: CanvasDropPayload) {
        let size = estimateScrapSize(for: payload)
        let scrap = ScrapItem(
            kind: payload.kind,
            text: payload.text,
            imageData: payload.imageData,
            position: payload.position,
            size: size,
            sourcePageIndex: payload.sourcePageIndex,
            sourceRect: payload.sourceRect
        )
        scrap.document = paper
        modelContext.insert(scrap)
    }

    private func estimateScrapSize(for payload: CanvasDropPayload) -> CGSize {
        switch payload.kind {
        case .text:
            let text = payload.text ?? ""
            let maxWidth: CGFloat = 320
            let font = UIFont.preferredFont(forTextStyle: .body)
            let bounding = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth - 20, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return CGSize(width: maxWidth, height: max(60, bounding.height + 24))
        case .image:
            if let data = payload.imageData, let img = UIImage(data: data) {
                let maxDim: CGFloat = 280
                let aspect = img.size.width / max(img.size.height, 1)
                if aspect >= 1 {
                    return CGSize(width: maxDim, height: maxDim / aspect)
                } else {
                    return CGSize(width: maxDim * aspect, height: maxDim)
                }
            }
            return CGSize(width: 200, height: 200)
        }
    }

    #if DEBUG
    private func addDummyTextScrap() {
        let position = nextDummyPosition()
        let scrap = ScrapItem(
            kind: .text,
            text: "샘플 텍스트 스크랩 #\(paper.scrapItems.count + 1)\nPhase 2 Step 2 검증용",
            position: position,
            size: CGSize(width: 280, height: 120),
            sourcePageIndex: currentPageIndex,
            sourceRect: .zero
        )
        scrap.document = paper
        modelContext.insert(scrap)
    }

    private func addDummyImageScrap() {
        let position = nextDummyPosition()
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let label = "IMG #\(paper.scrapItems.count + 1)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let s = NSAttributedString(string: label, attributes: attrs)
            let textSize = s.size()
            s.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                               y: (size.height - textSize.height) / 2))
        }
        let scrap = ScrapItem(
            kind: .image,
            imageData: image.pngData(),
            position: position,
            size: size,
            sourcePageIndex: currentPageIndex,
            sourceRect: .zero
        )
        scrap.document = paper
        modelContext.insert(scrap)
    }

    private func nextDummyPosition() -> CGPoint {
        let baseX = contentOffset.x + 80
        let baseY = contentOffset.y + 80
        let jitter = CGFloat(paper.scrapItems.count % 5) * 24
        return CGPoint(x: baseX + jitter, y: baseY + jitter)
    }
    #endif

    private func dividerDrag(totalWidth: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let baseWidth = totalWidth * leftFraction
                let proposed = (baseWidth + value.translation.width) / totalWidth
                leftFraction = max(minFraction, min(maxFraction, proposed))
            }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true

        currentPageIndex = paper.lastPageIndex
        contentOffset = CGPoint(x: paper.canvasOffsetX, y: paper.canvasOffsetY)
        if let data = paper.drawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasDrawing = drawing
        }
        pdfInkStrokes = resolvePageInkStrokes()

        guard let url = resolvePDFURL() else {
            loadError = "PDF를 찾을 수 없습니다"
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        if didStart { accessingURL = url }
        if let doc = PDFDocument(url: url) {
            pdfDocument = doc
        } else {
            if didStart { url.stopAccessingSecurityScopedResource() }
            accessingURL = nil
            loadError = "PDF 로드 실패"
        }
    }

    private func resolvePDFURL() -> URL? {
        if let bookmark = paper.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  bookmarkDataIsStale: &stale) {
                if stale, let refreshed = try? url.bookmarkData() {
                    paper.bookmarkData = refreshed
                }
                return url
            }
        }
        if let s = paper.sourceURLString {
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
            if let u = URL(string: s), u.isFileURL { return u }
        }
        return nil
    }

    private func scheduleSave() {
        guard didLoad else { return }
        saveTask?.cancel()
        savedStatusResetTask?.cancel()
        saveStatus = .saving
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persist()
            saveStatus = .saved(.now)
            scheduleSavedStatusReset()
        }
    }

    private func scheduleSavedStatusReset() {
        savedStatusResetTask?.cancel()
        savedStatusResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if case .saved = saveStatus { saveStatus = .idle }
        }
    }

    private func persist() {
        paper.lastPageIndex = currentPageIndex
        paper.canvasOffsetX = Double(contentOffset.x)
        paper.canvasOffsetY = Double(contentOffset.y)
        paper.drawingData = canvasDrawing.dataRepresentation()
        syncPageInkModels()
        paper.pdfInkData = nil
        paper.updatedAt = .now
    }

    private func resolvePageInkStrokes() -> [Int: [InkStroke]] {
        var strokesByPage: [Int: [InkStroke]] = [:]
        for ink in paper.pageInks {
            if let strokes = try? JSONDecoder().decode([InkStroke].self, from: ink.drawingData),
               !strokes.isEmpty {
                strokesByPage[ink.pageIndex] = strokes
            } else if let drawing = try? PKDrawing(data: ink.drawingData) {
                let strokes = PKDrawingConverter.toInkStrokes(drawing)
                if !strokes.isEmpty {
                    strokesByPage[ink.pageIndex] = strokes
                }
            }
        }
        if strokesByPage.isEmpty,
           let data = paper.pdfInkData,
           !data.isEmpty,
           let legacyDrawing = try? PKDrawing(data: data) {
            let strokes = PKDrawingConverter.toInkStrokes(legacyDrawing)
            if !strokes.isEmpty {
                strokesByPage[0] = strokes
            }
        }
        return strokesByPage
    }

    private func syncPageInkModels() {
        var existingByPage: [Int: PageInk] = [:]
        for ink in paper.pageInks {
            if existingByPage[ink.pageIndex] == nil {
                existingByPage[ink.pageIndex] = ink
            } else {
                modelContext.delete(ink)
            }
        }

        let activeStrokes = pdfInkStrokes.filter { !$0.value.isEmpty }
        for ink in paper.pageInks where activeStrokes[ink.pageIndex] == nil {
            modelContext.delete(ink)
        }

        for (pageIndex, strokes) in activeStrokes {
            guard let data = try? JSONEncoder().encode(strokes) else { continue }
            if let ink = existingByPage[pageIndex] {
                ink.drawingData = data
                ink.updatedAt = .now
                ink.document = paper
            } else {
                let ink = PageInk(pageIndex: pageIndex, drawingData: data)
                ink.document = paper
                modelContext.insert(ink)
            }
        }
    }

    private func handleDisappear() {
        saveTask?.cancel()
        savedStatusResetTask?.cancel()
        if didLoad { persist() }
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
    }
}

private struct DividerHandle: View {
    let visualWidth: CGFloat
    let hitWidth: CGFloat

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.Rule.hairline)
                .frame(width: visualWidth)
            Capsule()
                .fill(Color.Ink.tertiary)
                .frame(width: 3, height: 36)
                .chromeGlassCapsule()
        }
        .frame(width: hitWidth)
        .contentShape(.rect)
        .hoverEffect(.lift)
    }
}
