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

    @State private var activePaperID: UUID?
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

    private var activePaper: PaperDocument {
        guard let activePaperID,
              let paper = libraryPapers.first(where: { $0.id == activePaperID }) else {
            return paper
        }
        return paper
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
        CanvasBackground(rawValue: activePaper.canvasBackgroundRaw) ?? .dots
    }

    private var hasPDFSource: Bool {
        activePaper.bookmarkData != nil || !(activePaper.sourceURLString?.isEmpty ?? true)
    }

    var body: some View {
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
                    CanvasView(drawing: $canvasDrawing,
                               contentOffset: $contentOffset,
                               resetTrigger: $canvasResetTrigger,
                               initialContentSize: CGSize(
                                   width: activePaper.canvasContentWidth,
                                   height: activePaper.canvasContentHeight),
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

                    sideDock(palette: paletteCanvas, edge: .trailing)
                }
                .frame(width: canvasWidth)
            }
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .top, spacing: 0) {
            SplitTopBar(
                noteTitle: noteDisplayTitle,
                canvasTitle: canvasDisplayTitle,
                activePaperID: activePaper.id,
                documents: switchablePapers,
                documentSwitcherKind: documentSwitcherKind,
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
                onSelectDocumentSwitcherKind: selectDocumentSwitcherKind,
                onSelectDocument: switchToPaper,
                canvasBackground: canvasBackground,
                onPickCanvasBackground: { type in
                    activePaper.canvasBackgroundRaw = type.rawValue
                    activePaper.updatedAt = .now
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
        .task(id: activePaper.id) { await loadIfNeeded() }
        .onChange(of: canvasDrawing) { _, _ in scheduleSave() }
        .onChange(of: pdfInkStrokes) { _, _ in scheduleSave() }
        .onChange(of: contentOffset) { _, _ in scheduleSave() }
        .onChange(of: currentPageIndex) { _, _ in scheduleSave() }
        .onDisappear { handleDisappear() }
    }

    private var noteDisplayTitle: String {
        activePaper.documentKind == .note ? activePaper.title : "노트 선택"
    }

    private var canvasDisplayTitle: String {
        activePaper.documentKind == .canvas ? activePaper.title : "캔버스"
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
        activePaper.scrapItems.sorted(by: { $0.createdAt < $1.createdAt })
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
        guard let scrap = activePaper.scrapItems.first(where: { $0.id == id }) else { return }
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
        scrap.document = activePaper
        modelContext.insert(scrap)
        activePaper.updatedAt = .now
        scheduleSave()
    }

    private func imageDisplaySize(for image: UIImage) -> CGSize {
        let maxDim: CGFloat = 320
        let aspect = image.size.width / max(image.size.height, 1)
        if aspect >= 1 { return CGSize(width: maxDim, height: maxDim / aspect) }
        return CGSize(width: maxDim * aspect, height: maxDim)
    }

    private func handleScrapMoved(_ id: UUID, _ position: CGPoint) {
        guard let scrap = activePaper.scrapItems.first(where: { $0.id == id }) else { return }
        scrap.positionX = Double(position.x)
        scrap.positionY = Double(position.y)
        activePaper.updatedAt = .now
        scheduleSave()
    }

    private func handleScrapResized(_ id: UUID, _ size: CGSize) {
        guard let scrap = activePaper.scrapItems.first(where: { $0.id == id }) else { return }
        scrap.width = Double(size.width)
        scrap.height = Double(size.height)
        activePaper.updatedAt = .now
        scheduleSave()
    }

    private func handleScrapDeleted(_ id: UUID) {
        guard let scrap = activePaper.scrapItems.first(where: { $0.id == id }) else { return }
        modelContext.delete(scrap)
        activePaper.updatedAt = .now
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
        scrap.document = activePaper
        modelContext.insert(scrap)
        activePaper.updatedAt = .now
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
        guard let scrap = activePaper.scrapItems.first(where: { $0.id == id }),
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
           let scrap = activePaper.scrapItems.first(where: { $0.id == scrapID }) {
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
            scrap.document = activePaper
            modelContext.insert(scrap)
        }

        activePaper.updatedAt = .now
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
            text: "샘플 텍스트 스크랩 #\(activePaper.scrapItems.count + 1)\nPhase 2 Step 2 검증용",
            position: position,
            size: CGSize(width: 280, height: 120),
            sourcePageIndex: currentPageIndex,
            sourceRect: .zero
        )
        scrap.document = activePaper
        modelContext.insert(scrap)
    }

    private func addDummyImageScrap() {
        let position = nextDummyPosition()
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let label = "IMG #\(activePaper.scrapItems.count + 1)"
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
        scrap.document = activePaper
        modelContext.insert(scrap)
    }

    private func nextDummyPosition() -> CGPoint {
        let baseX = contentOffset.x + 80
        let baseY = contentOffset.y + 80
        let jitter = CGFloat(activePaper.scrapItems.count % 5) * 24
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
        withAnimation(Motion.indirectFast) {
            documentSwitcherKind = documentSwitcherKind == kind ? nil : kind
        }
    }

    private func selectDocumentSwitcherKind(_ kind: PaperDocumentKind) {
        withAnimation(Motion.indirectFast) {
            documentSwitcherKind = kind
        }
    }

    private func switchToPaper(_ target: PaperDocument) {
        guard target.id != activePaper.id else {
            withAnimation(Motion.indirectFast) {
                documentSwitcherKind = nil
            }
            return
        }

        saveTask?.cancel()
        savedStatusResetTask?.cancel()
        if didLoad { persist() }
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil

        resetActivePaperSession()
        withAnimation(Motion.indirectFast) {
            activePaperID = target.id
            documentSwitcherKind = nil
        }
    }

    private func resetActivePaperSession() {
        pdfDocument = nil
        canvasDrawing = PKDrawing()
        pdfInkStrokes = [:]
        contentOffset = .zero
        currentPageIndex = 0
        navigationTarget = nil
        canvasResetTrigger = UUID()
        leftFraction = 0.5
        loadError = nil
        didLoad = false
        saveTask = nil
        savedStatusResetTask = nil
        saveStatus = .idle
        canvasZoomScale = 1.0
        showingPageJumpSheet = false
        textNoteDraft = nil
        palettePDF.isStrokeInProgress = false
        paletteCanvas.isStrokeInProgress = false
        activeInputSurface = .canvas
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true

        currentPageIndex = activePaper.lastPageIndex
        contentOffset = CGPoint(x: activePaper.canvasOffsetX, y: activePaper.canvasOffsetY)
        if let data = activePaper.drawingData,
           let drawing = try? PKDrawing(data: data) {
            canvasDrawing = drawing
        }
        pdfInkStrokes = resolvePageInkStrokes()

        guard hasPDFSource else {
            pdfDocument = nil
            loadError = nil
            return
        }

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
        if let bookmark = activePaper.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  bookmarkDataIsStale: &stale) {
                if stale, let refreshed = try? url.bookmarkData() {
                    activePaper.bookmarkData = refreshed
                }
                return url
            }
        }
        if let s = activePaper.sourceURLString {
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
        activePaper.lastPageIndex = currentPageIndex
        activePaper.canvasOffsetX = Double(contentOffset.x)
        activePaper.canvasOffsetY = Double(contentOffset.y)
        activePaper.drawingData = canvasDrawing.dataRepresentation()
        syncPageInkModels()
        activePaper.pdfInkData = nil
        activePaper.updatedAt = .now
    }

    private func resolvePageInkStrokes() -> [Int: [InkStroke]] {
        var strokesByPage: [Int: [InkStroke]] = [:]
        for ink in activePaper.pageInks {
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
           let data = activePaper.pdfInkData,
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
        for ink in activePaper.pageInks {
            if existingByPage[ink.pageIndex] == nil {
                existingByPage[ink.pageIndex] = ink
            } else {
                modelContext.delete(ink)
            }
        }

        let activeStrokes = pdfInkStrokes.filter { !$0.value.isEmpty }
        for ink in activePaper.pageInks where activeStrokes[ink.pageIndex] == nil {
            modelContext.delete(ink)
        }

        for (pageIndex, strokes) in activeStrokes {
            guard let data = try? JSONEncoder().encode(strokes) else { continue }
            if let ink = existingByPage[pageIndex] {
                ink.drawingData = data
                ink.updatedAt = .now
                ink.document = activePaper
            } else {
                let ink = PageInk(pageIndex: pageIndex, drawingData: data)
                ink.document = activePaper
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
