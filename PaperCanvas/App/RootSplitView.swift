import SwiftUI
import SwiftData
import PDFKit
import PencilKit

private enum InputSurface {
    case note
    case canvas
}

struct RootSplitView: View {
    @Bindable var paper: PaperDocument

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PaperDocument.updatedAt, order: .reverse) private var libraryPapers: [PaperDocument]

    @State private var activeNotePaperID: UUID?
    @State private var activeCanvasPaperID: UUID?
    @State private var pdfDocument: PDFDocument?
    @State private var canvasDrawing = PKDrawing()
    @State private var pdfInkStrokes: [Int: [InkStroke]] = [:]
    @State private var contentOffset: CGPoint = .zero
    @State private var currentPageIndex: Int = 0
    @State private var navigationTarget: PDFNavigationTarget?
    @State private var canvasResetTrigger: UUID?
    @State private var leftFraction: CGFloat = 0.5
    @State private var loadError: String?
    @State private var didLoadNote = false
    @State private var didLoadCanvas = false
    @State private var palettePDF = PaletteState()
    @State private var paletteCanvas = PaletteState()
    @State private var activeInputSurface: InputSurface = .canvas

    @State private var accessingURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveStatus: SaveStatus = .idle
    @State private var canvasZoomScale: CGFloat = 1.0
    @State private var showingPageJumpSheet = false
    @State private var textNoteDraft: CanvasTextNoteDraft?
    @State private var savedStatusResetTask: Task<Void, Never>?
    @State private var documentSwitcherKind: PaperDocumentKind?
    @Namespace private var documentSwitcherNamespace
    @AppStorage("PaperCanvas.autoHideTopBar") private var autoHideTopBar = false

    private var activeNotePaper: PaperDocument? {
        guard let id = activeNotePaperID else { return nil }
        return libraryPapers.first(where: { $0.id == id })
    }

    private var activeCanvasPaper: PaperDocument? {
        guard let id = activeCanvasPaperID else { return nil }
        return libraryPapers.first(where: { $0.id == id })
    }

    /// Paper used as a fallback for context (folder lookup, etc.) when one of
    /// the panes is empty. Prefers whichever pane is currently populated.
    private var contextPaper: PaperDocument {
        activeNotePaper ?? activeCanvasPaper ?? paper
    }

    private var switchablePapers: [PaperDocument] {
        libraryPapers
            .filter { !$0.isDeleted && $0.folder?.isDeleted != true }
            .sorted { lhs, rhs in
                if lhs.documentKind != rhs.documentKind {
                    return lhs.documentKind == .note
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private var anyStrokeInProgress: Bool {
        palettePDF.isStrokeInProgress || paletteCanvas.isStrokeInProgress
    }

    private var chromeOpacity: Double {
        guard anyStrokeInProgress else { return 1.0 }
        return autoHideTopBar ? 0.0 : Motion.dimDuringStrokeOpacity
    }

    private let dividerVisualWidth: CGFloat = 8
    private let dividerHitWidth: CGFloat = 28
    private let minFraction: CGFloat = 0.2
    private let maxFraction: CGFloat = 0.8

    private var canvasBackground: CanvasBackground {
        guard let raw = activeCanvasPaper?.canvasBackgroundRaw else { return .dots }
        return CanvasBackground(rawValue: raw) ?? .dots
    }

    private var hasPDFSource: Bool {
        guard let note = activeNotePaper else { return false }
        return note.bookmarkData != nil || !(note.sourceURLString?.isEmpty ?? true)
    }

    var body: some View {
        ZStack {
            mainContent
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        .sheet(item: $documentSwitcherKind) { kind in
            DocumentSwitcherPanel(
                selectedKind: kind,
                documents: switchablePapers,
                activePaperID: kind == .note ? activeNotePaperID : activeCanvasPaperID,
                onSelectDocument: { paper in
                    switchToPaper(paper)
                },
                onCreateDocument: {
                    createDocument(of: kind)
                }
            )
            .presentationDetents([.height(560)])
            .presentationBackground(.clear)
            .presentationDragIndicator(.hidden)
            .presentationCompactAdaptation(.popover)
            .navigationTransition(.zoom(sourceID: kind,
                                        in: documentSwitcherNamespace))
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
        .sheet(item: $textNoteDraft) { draft in
            CanvasTextNoteSheet(
                draft: draft,
                onCancel: { textNoteDraft = nil },
                onSave: saveTextNote
            )
        }
        .task { setupInitialActivePapers() }
        .task(id: activeNotePaperID) { await loadNoteIfNeeded() }
        .task(id: activeCanvasPaperID) { await loadCanvasIfNeeded() }
        .onChange(of: canvasDrawing) { _, _ in scheduleSave() }
        .onChange(of: pdfInkStrokes) { _, _ in scheduleSave() }
        .onChange(of: contentOffset) { _, _ in scheduleSave() }
        .onChange(of: currentPageIndex) { _, _ in scheduleSave() }
        .onDisappear { handleDisappear() }
    }

    private func setupInitialActivePapers() {
        guard activeNotePaperID == nil, activeCanvasPaperID == nil else { return }
        switch paper.documentKind {
        case .note:
            activeNotePaperID = paper.id
            activeInputSurface = .note
            if let companion = resolveCompanion(for: paper, expecting: .canvas) {
                activeCanvasPaperID = companion.id
            }
        case .canvas:
            activeCanvasPaperID = paper.id
            activeInputSurface = .canvas
            if let companion = resolveCompanion(for: paper, expecting: .note) {
                activeNotePaperID = companion.id
            }
        }
    }

    private func resolveCompanion(for paper: PaperDocument,
                                  expecting kind: PaperDocumentKind) -> PaperDocument? {
        guard let companionID = paper.companionPaperID else { return nil }
        guard let companion = libraryPapers.first(where: { $0.id == companionID }) else { return nil }
        guard !companion.isDeleted, companion.folder?.isDeleted != true else { return nil }
        guard companion.documentKind == kind else { return nil }
        return companion
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let leftWidth = max(totalWidth * minFraction,
                                min(totalWidth * maxFraction,
                                    totalWidth * leftFraction))
            let rightWidth = max(0, totalWidth - leftWidth - dividerVisualWidth)
            let canvasWidth = hasPDFSource ? max(0, rightWidth - (dividerHitWidth - dividerVisualWidth)) : totalWidth

            HStack(spacing: 0) {
                if hasPDFSource {
                    ZStack(alignment: .leading) {
                        leftPane
                        sideDock(palette: palettePDF, edge: .leading)
                    }
                    .frame(width: leftWidth)

                    DividerHandle(visualWidth: dividerVisualWidth,
                                  hitWidth: dividerHitWidth)
                        .frame(width: dividerHitWidth)
                        .gesture(dividerDrag(totalWidth: totalWidth))
                }

                ZStack(alignment: .trailing) {
                    if activeCanvasPaper == nil {
                        emptyPaneState(kind: .canvas)
                    } else {
                    CanvasView(drawing: $canvasDrawing,
                               contentOffset: $contentOffset,
                               resetTrigger: $canvasResetTrigger,
                               initialContentSize: CGSize(
                                   width: activeCanvasPaper?.canvasContentWidth ?? 4000,
                                   height: activeCanvasPaper?.canvasContentHeight ?? 4000),
                               scraps: sortedScraps,
                               palette: paletteCanvas,
                               background: canvasBackground,
                               onScrapTap: handleScrapTap,
                               onDrop: handleCanvasDrop,
                               onScrapMoved: handleScrapMoved,
                               onScrapResized: handleScrapResized,
                               onScrapEditRequested: beginEditingTextNote,
                               onScrapDeleted: handleScrapDeleted,
                               onZoomChanged: { scale in
                                   canvasZoomScale = scale
                               },
                               onCanvasActivated: {
                                   activeInputSurface = .canvas
                               },
                               onPencilTap: handlePencilTap,
                               onStrokeBegan: {
                                   activeInputSurface = .canvas
                                   paletteCanvas.isStrokeInProgress = true
                               },
                               onStrokeEnded: {
                                   paletteCanvas.isStrokeInProgress = false
                               })
                    }

                    sideDock(palette: paletteCanvas, edge: .trailing)
                }
                .frame(width: canvasWidth)
            }
        }
    }

    @ViewBuilder
    private func emptyPaneState(kind: PaperDocumentKind) -> some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 36))
                .foregroundStyle(Color.Ink.tertiary)
            Text(kind == .note ? "노트가 선택되지 않았습니다" : "캔버스가 선택되지 않았습니다")
                .font(AppType.callout)
                .foregroundStyle(Color.Ink.secondary)
            Text("상단 제목을 눌러 선택하거나 새로 추가하세요")
                .font(AppType.caption)
                .foregroundStyle(Color.Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Surface.subtle)
    }

    @ViewBuilder
    private var topBar: some View {
        SplitTopBar(
            noteTitle: noteDisplayTitle,
            canvasTitle: canvasDisplayTitle,
            documentSwitcherNamespace: documentSwitcherNamespace,
            pageIndex: currentPageIndex,
            totalPages: pdfDocument?.pageCount ?? 0,
            canvasZoom: canvasZoomScale,
            onLibraryTap: {
                handleDisappear()
                dismiss()
            },
            onPageJumpTap: { showingPageJumpSheet = true },
            onZoomReset: { canvasResetTrigger = UUID() },
            onRecenterCanvas: { canvasResetTrigger = UUID() },
            onAddTextNote: beginAddingTextNote,
            onToggleDocumentSwitcher: toggleDocumentSwitcher,
            canvasBackground: canvasBackground,
            onPickCanvasBackground: { type in
                guard let canvas = activeCanvasPaper else { return }
                canvas.canvasBackgroundRaw = type.rawValue
                canvas.updatedAt = .now
                scheduleSave()
            },
            debugActions: debugActions
        )
        .padding(.horizontal, TopBarMetrics.outerHorizontalPadding)
        .padding(.top, TopBarMetrics.outerTopPadding)
        .padding(.bottom, TopBarMetrics.outerBottomPadding)
        .opacity(chromeOpacity)
        .animation(Motion.chromeFade, value: chromeOpacity)
        .allowsHitTesting(chromeOpacity > 0.05)
    }

    private var noteDisplayTitle: String {
        activeNotePaper?.title ?? "노트 선택"
    }

    private var canvasDisplayTitle: String {
        activeCanvasPaper?.title ?? "캔버스 선택"
    }

    @ViewBuilder
    private func sideDock(palette: PaletteState, edge: Edge) -> some View {
        PaletteToolbar(
            palette: palette,
            layout: .vertical,
            popoverArrowEdge: edge == .leading ? .leading : .trailing
        )
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))
        .padding(sideDockPadding(for: edge), Spacing.s)
            .opacity(chromeOpacity)
            .animation(Motion.chromeFade, value: chromeOpacity)
            .allowsHitTesting(chromeOpacity > 0.05)
    }

    private func sideDockPadding(for edge: Edge) -> Edge.Set {
        edge == .leading ? .leading : .trailing
    }

    @ViewBuilder
    private var leftPane: some View {
        if let pdfDocument {
            PDFKitView(document: pdfDocument,
                       currentPageIndex: $currentPageIndex,
                       navigationTarget: $navigationTarget,
                       pageInkStrokes: $pdfInkStrokes,
                       palette: palettePDF,
                       onRegionCaptured: handleRegionCaptured,
                       onPDFInkActivated: {
                           activeInputSurface = .note
                       },
                       onPencilTap: handlePencilTap)
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

    private var debugActions: SplitTopBar.DebugActions? {
        #if DEBUG
        SplitTopBar.DebugActions(
            addTextScrap: addDummyTextScrap,
            addImageScrap: addDummyImageScrap
        )
        #else
        nil
        #endif
    }

    private var sortedScraps: [ScrapItem] {
        (activeCanvasPaper?.scrapItems ?? []).sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func handlePencilTap() {
        switch activeInputSurface {
        case .note:
            palettePDF.switchToPreviousTool()
        case .canvas:
            paletteCanvas.switchToPreviousTool()
        }
    }

    private func handleScrapTap(_ id: UUID) {
        guard let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == id }) else { return }
        let rect = CGRect(x: scrap.sourceRectX,
                          y: scrap.sourceRectY,
                          width: scrap.sourceRectW,
                          height: scrap.sourceRectH)
        if scrap.kind == .text, rect.isEmpty {
            beginEditingTextNote(id)
            return
        }
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
        scrap.document = activeCanvasPaper
        modelContext.insert(scrap)
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
    }

    private func imageDisplaySize(for image: UIImage) -> CGSize {
        let maxDim: CGFloat = 320
        let aspect = image.size.width / max(image.size.height, 1)
        if aspect >= 1 { return CGSize(width: maxDim, height: maxDim / aspect) }
        return CGSize(width: maxDim * aspect, height: maxDim)
    }

    private func handleScrapMoved(_ id: UUID, _ position: CGPoint) {
        guard let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == id }) else { return }
        scrap.positionX = Double(position.x)
        scrap.positionY = Double(position.y)
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
    }

    private func handleScrapResized(_ id: UUID, _ size: CGSize) {
        guard let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == id }) else { return }
        scrap.width = Double(size.width)
        scrap.height = Double(size.height)
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
    }

    private func handleScrapDeleted(_ id: UUID) {
        guard let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == id }) else { return }
        modelContext.delete(scrap)
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
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
        scrap.document = activeCanvasPaper
        modelContext.insert(scrap)
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
    }

    private func estimateScrapSize(for payload: CanvasDropPayload) -> CGSize {
        switch payload.kind {
        case .text:
            return estimateTextNoteSize(for: payload.text ?? "")
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

    private func beginAddingTextNote() {
        textNoteDraft = CanvasTextNoteDraft(scrapID: nil, text: "")
    }

    private func beginEditingTextNote(_ id: UUID) {
        guard let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == id }),
              scrap.kind == .text else { return }
        textNoteDraft = CanvasTextNoteDraft(scrapID: id, text: scrap.text ?? "")
    }

    private func saveTextNote(_ draft: CanvasTextNoteDraft, _ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            textNoteDraft = nil
            return
        }

        if let scrapID = draft.scrapID,
           let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == scrapID }) {
            scrap.text = text
            let estimated = estimateTextNoteSize(
                for: text,
                maxWidth: max(220, CGFloat(scrap.width))
            )
            scrap.height = Double(max(CGFloat(scrap.height), estimated.height))
        } else {
            let position = CGPoint(x: contentOffset.x + 120, y: contentOffset.y + 120)
            let scrap = ScrapItem(
                kind: .text,
                text: text,
                position: position,
                size: estimateTextNoteSize(for: text),
                sourcePageIndex: currentPageIndex,
                sourceRect: .zero
            )
            scrap.document = activeCanvasPaper
            modelContext.insert(scrap)
        }

        activeCanvasPaper?.updatedAt = .now
        textNoteDraft = nil
        scheduleSave()
    }

    private func estimateTextNoteSize(for text: String, maxWidth: CGFloat = 320) -> CGSize {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth - 20, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return CGSize(width: maxWidth, height: max(72, bounding.height + 28))
    }

    #if DEBUG
    private func addDummyTextScrap() {
        let position = nextDummyPosition()
        let scrap = ScrapItem(
            kind: .text,
            text: "샘플 텍스트 스크랩 #\((activeCanvasPaper?.scrapItems ?? []).count + 1)\nPhase 2 Step 2 검증용",
            position: position,
            size: CGSize(width: 280, height: 120),
            sourcePageIndex: currentPageIndex,
            sourceRect: .zero
        )
        scrap.document = activeCanvasPaper
        modelContext.insert(scrap)
    }

    private func addDummyImageScrap() {
        let position = nextDummyPosition()
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let label = "IMG #\((activeCanvasPaper?.scrapItems ?? []).count + 1)"
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
        scrap.document = activeCanvasPaper
        modelContext.insert(scrap)
    }

    private func nextDummyPosition() -> CGPoint {
        let baseX = contentOffset.x + 80
        let baseY = contentOffset.y + 80
        let jitter = CGFloat((activeCanvasPaper?.scrapItems ?? []).count % 5) * 24
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

    private func toggleDocumentSwitcher(_ kind: PaperDocumentKind) {
        // The sheet+zoom presentation drives its own Liquid Glass morph from the
        // matchedTransitionSource on the title capsule, so we just toggle state
        // without an explicit animation transaction.
        documentSwitcherKind = documentSwitcherKind == kind ? nil : kind
    }

    private func createDocument(of kind: PaperDocumentKind) {
        let title = nextBlankTitle(for: kind)
        let newPaper = PaperDocument(title: title, kind: kind)
        let preferredFolder: PaperFolder? = {
            switch kind {
            case .note:   return activeNotePaper?.folder ?? activeCanvasPaper?.folder
            case .canvas: return activeCanvasPaper?.folder ?? activeNotePaper?.folder
            }
        }()
        if let folder = preferredFolder {
            newPaper.folder = folder
            folder.updatedAt = .now
        }
        modelContext.insert(newPaper)
        try? modelContext.save()
        switchToPaper(newPaper)
    }

    private func nextBlankTitle(for kind: PaperDocumentKind) -> String {
        let base = kind == .note ? "새 노트" : "새 캔버스"
        let titles = Set(libraryPapers.map(\.title))
        if !titles.contains(base) { return base }
        var idx = 2
        while titles.contains("\(base) \(idx)") { idx += 1 }
        return "\(base) \(idx)"
    }

    /// Route the selection to the pane matching the paper's kind. The other
    /// pane is untouched, so note and canvas live independently.
    private func switchToPaper(_ target: PaperDocument) {
        switch target.documentKind {
        case .note:
            guard target.id != activeNotePaperID else {
                documentSwitcherKind = nil
                return
            }
            saveTask?.cancel()
            savedStatusResetTask?.cancel()
            if didLoadNote { persistNote() }
            accessingURL?.stopAccessingSecurityScopedResource()
            accessingURL = nil
            resetNotePane()
            target.companionPaperID = activeCanvasPaperID
            target.updatedAt = .now
            activeNotePaperID = target.id
            documentSwitcherKind = nil
        case .canvas:
            guard target.id != activeCanvasPaperID else {
                documentSwitcherKind = nil
                return
            }
            saveTask?.cancel()
            savedStatusResetTask?.cancel()
            if didLoadCanvas { persistCanvas() }
            resetCanvasPane()
            target.companionPaperID = activeNotePaperID
            target.updatedAt = .now
            activeCanvasPaperID = target.id
            documentSwitcherKind = nil
        }
    }

    private func resetNotePane() {
        pdfDocument = nil
        pdfInkStrokes = [:]
        currentPageIndex = 0
        navigationTarget = nil
        loadError = nil
        didLoadNote = false
        palettePDF.isStrokeInProgress = false
        showingPageJumpSheet = false
    }

    private func resetCanvasPane() {
        canvasDrawing = PKDrawing()
        contentOffset = .zero
        canvasResetTrigger = UUID()
        canvasZoomScale = 1.0
        didLoadCanvas = false
        paletteCanvas.isStrokeInProgress = false
        textNoteDraft = nil
        activeInputSurface = .canvas
    }

    private func loadNoteIfNeeded() async {
        guard !didLoadNote, let note = activeNotePaper else { return }
        didLoadNote = true

        currentPageIndex = note.lastPageIndex
        pdfInkStrokes = resolvePageInkStrokes(for: note)

        guard hasPDFSource else {
            pdfDocument = nil
            loadError = nil
            return
        }

        guard let url = resolvePDFURL(for: note) else {
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

    private func loadCanvasIfNeeded() async {
        guard !didLoadCanvas, let canvas = activeCanvasPaper else { return }
        didLoadCanvas = true

        contentOffset = CGPoint(x: canvas.canvasOffsetX, y: canvas.canvasOffsetY)
        if let data = canvas.drawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasDrawing = drawing
        } else {
            canvasDrawing = PKDrawing()
        }
    }

    private func resolvePDFURL(for note: PaperDocument) -> URL? {
        if let bookmark = note.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  bookmarkDataIsStale: &stale) {
                if stale, let refreshed = try? url.bookmarkData() {
                    note.bookmarkData = refreshed
                }
                return url
            }
        }
        if let s = note.sourceURLString {
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
            if let u = URL(string: s), u.isFileURL { return u }
        }
        return nil
    }

    private func scheduleSave() {
        guard didLoadNote || didLoadCanvas else { return }
        saveTask?.cancel()
        savedStatusResetTask?.cancel()
        saveStatus = .saving
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistAll()
            saveStatus = .saved(.now)
            scheduleSavedStatusReset()
        }
    }

    private func persistAll() {
        if didLoadNote { persistNote() }
        if didLoadCanvas { persistCanvas() }
    }

    private func scheduleSavedStatusReset() {
        savedStatusResetTask?.cancel()
        savedStatusResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if case .saved = saveStatus { saveStatus = .idle }
        }
    }

    private func persistNote() {
        guard let note = activeNotePaper else { return }
        note.lastPageIndex = currentPageIndex
        syncPageInkModels(into: note)
        note.pdfInkData = nil
        note.companionPaperID = activeCanvasPaperID
        note.updatedAt = .now
    }

    private func persistCanvas() {
        guard let canvas = activeCanvasPaper else { return }
        canvas.canvasOffsetX = Double(contentOffset.x)
        canvas.canvasOffsetY = Double(contentOffset.y)
        canvas.drawingData = canvasDrawing.dataRepresentation()
        canvas.companionPaperID = activeNotePaperID
        canvas.updatedAt = .now
    }

    private func resolvePageInkStrokes(for note: PaperDocument) -> [Int: [InkStroke]] {
        var strokesByPage: [Int: [InkStroke]] = [:]
        for ink in note.pageInks {
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
           let data = note.pdfInkData,
           !data.isEmpty,
           let legacyDrawing = try? PKDrawing(data: data) {
            let strokes = PKDrawingConverter.toInkStrokes(legacyDrawing)
            if !strokes.isEmpty {
                strokesByPage[0] = strokes
            }
        }
        return strokesByPage
    }

    private func syncPageInkModels(into note: PaperDocument) {
        var existingByPage: [Int: PageInk] = [:]
        for ink in note.pageInks {
            if existingByPage[ink.pageIndex] == nil {
                existingByPage[ink.pageIndex] = ink
            } else {
                modelContext.delete(ink)
            }
        }

        let activeStrokes = pdfInkStrokes.filter { !$0.value.isEmpty }
        for ink in note.pageInks where activeStrokes[ink.pageIndex] == nil {
            modelContext.delete(ink)
        }

        for (pageIndex, strokes) in activeStrokes {
            guard let data = try? JSONEncoder().encode(strokes) else { continue }
            if let ink = existingByPage[pageIndex] {
                ink.drawingData = data
                ink.updatedAt = .now
                ink.document = note
            } else {
                let ink = PageInk(pageIndex: pageIndex, drawingData: data)
                ink.document = note
                modelContext.insert(ink)
            }
        }
    }

    private func handleDisappear() {
        saveTask?.cancel()
        savedStatusResetTask?.cancel()
        persistAll()
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

private struct CanvasTextNoteDraft: Identifiable, Equatable {
    let id = UUID()
    let scrapID: UUID?
    var text: String

    var isNew: Bool {
        scrapID == nil
    }
}

private struct CanvasTextNoteSheet: View {
    let draft: CanvasTextNoteDraft
    let onCancel: () -> Void
    let onSave: (CanvasTextNoteDraft, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(draft: CanvasTextNoteDraft,
         onCancel: @escaping () -> Void,
         onSave: @escaping (CanvasTextNoteDraft, String) -> Void) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(AppType.body)
                .foregroundStyle(Color.Ink.primary)
                .scrollContentBackground(.hidden)
                .background(Color.Surface.paper)
                .padding(Spacing.m)
                .navigationTitle(draft.isNew ? "텍스트 메모 추가" : "텍스트 메모 편집")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("취소") {
                            onCancel()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") {
                            onSave(draft, text)
                            dismiss()
                        }
                        .disabled(trimmedText.isEmpty)
                    }
                }
                .focused($isFocused)
        }
        .presentationDetents([.medium, .large])
        .task {
            isFocused = true
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
