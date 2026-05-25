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
    @State private var blankNoteDrawing = PKDrawing()
    @State private var pdfInkStrokes: [Int: [InkStroke]] = [:]
    @State private var contentOffset: CGPoint = .zero
    @State private var currentPageIndex: Int = 0
    @State private var navigationTarget: PDFNavigationTarget?
    @State private var pendingArrowSource: CGRect?
    @State private var navigationArrow: NavigationArrow?
    @State private var canvasResetTrigger: UUID?
    @State private var anchorScrapListAnchor: AnchorRef?
    @State private var anchorScrapListItems: [ScrapItem] = []
    @State private var pendingDeletion: PendingAnchorDeletion?
    @AppStorage("PaperCanvas.anchorScrapDeletionMode") private var anchorScrapDeletionModeRaw: String = ""
    @State private var leftFraction: CGFloat = 0.5
    @State private var dividerDragStartFraction: CGFloat?
    @State private var isCanvasOnLeft: Bool = false
    @State private var showDividerActions: Bool = false
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
    private let splitOnlySnapFraction: CGFloat = 0.04

    private var canvasBackground: CanvasBackground {
        guard let raw = activeCanvasPaper?.canvasBackgroundRaw else { return .dots }
        return CanvasBackground(rawValue: raw) ?? .dots
    }

    private var hasPDFSource: Bool {
        activeNotePaper?.hasPDFSource ?? false
    }

    /// True when the note pane should show the blank, page-based editor
    /// (PaperDocument of kind .note without a backing PDF).
    private var isBlankPagedNote: Bool {
        activeNotePaper?.isBlankPagedNote ?? false
    }

    /// True when the note pane has any content to render in the left split.
    /// We mirror the PDF-pane visibility for the divider so blank notes also
    /// get the split layout.
    private var hasLeftPaneContent: Bool {
        hasPDFSource || isBlankPagedNote
    }

    var body: some View {
        ZStack {
            mainContent
            documentSwitcherScrim
            NavigationArrowOverlay(arrow: navigationArrow)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                withAnimation(Motion.indirect) {
                    showDividerActions = false
                }
            },
            including: showDividerActions ? .all : .none
        )
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
        .sheet(item: $anchorScrapListAnchor) { anchor in
            AnchorScrapsSheet(
                anchor: anchor,
                scraps: anchorScrapListItems,
                onSelect: { scrap in
                    centerCanvasOn(scrap: scrap)
                    anchorScrapListAnchor = nil
                },
                onDelete: { scrap in
                    requestDeletion(.scrap(scrap))
                },
                onClose: { anchorScrapListAnchor = nil }
            )
            .presentationDetents([.fraction(0.35), .medium])
        }
        .confirmationDialog(
            "연결된 항목도 함께 삭제하시겠어요?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button("이 항목만 삭제", role: .destructive) {
                if deletion.rememberChoice {
                    anchorScrapDeletionModeRaw = AnchorDeletionMode.independent.rawValue
                }
                performDeletion(target: deletion.target, cascade: false)
                pendingDeletion = nil
            }
            Button("연결된 것도 함께 삭제", role: .destructive) {
                if deletion.rememberChoice {
                    anchorScrapDeletionModeRaw = AnchorDeletionMode.cascade.rawValue
                }
                performDeletion(target: deletion.target, cascade: true)
                pendingDeletion = nil
            }
            Button("취소", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("이 선택을 기억해 다음부터 자동 적용됩니다.")
        }
        .task { setupInitialActivePapers() }
        .task(id: activeNotePaperID) { await loadNoteIfNeeded() }
        .task(id: activeCanvasPaperID) { await loadCanvasIfNeeded() }
        .onChange(of: canvasDrawing) { _, _ in scheduleSave() }
        .onChange(of: blankNoteDrawing) { _, _ in scheduleSave() }
        .onChange(of: paletteCanvas.isStrokeInProgress) { _, started in
            if started, showDividerActions {
                withAnimation(Motion.indirect) { showDividerActions = false }
            }
        }
        .onChange(of: palettePDF.isStrokeInProgress) { _, started in
            if started, showDividerActions {
                withAnimation(Motion.indirect) { showDividerActions = false }
            }
        }
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
    private var documentSwitcherScrim: some View {
        if documentSwitcherKind != nil {
            // Invisible tap target covering everything except the switcher panel
            // itself. Tapping anywhere outside dismisses the panel — standard
            // popover behavior. The panel lives inside the top bar's safeAreaInset
            // overlay, which renders above this scrim, so its hit-testing wins.
            Color.clear
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(Motion.indirect) {
                        documentSwitcherKind = nil
                    }
                }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let isDraggingDivider = dividerDragStartFraction != nil
            let isRightOnly = hasLeftPaneContent && !isDraggingDivider && leftFraction <= 0
            let isLeftOnly = hasLeftPaneContent && !isDraggingDivider && leftFraction >= 1
            let splitFraction = isDraggingDivider
                ? max(0, min(1, leftFraction))
                : max(minFraction, min(maxFraction, leftFraction))
            let leftWidth = isLeftOnly ? totalWidth : (isRightOnly ? 0 : totalWidth * splitFraction)
            let rightWidth: CGFloat = {
                guard hasLeftPaneContent else { return totalWidth }
                if isRightOnly { return totalWidth }
                if isLeftOnly { return 0 }
                return max(0, totalWidth - leftWidth)
            }()
            let dividerCenterX = max(dividerHitWidth * 0.5,
                                     min(totalWidth - dividerHitWidth * 0.5,
                                         leftWidth))
            let leftIsCanvas = isCanvasOnLeft && hasLeftPaneContent

            ZStack {
                HStack(spacing: 0) {
                    if hasLeftPaneContent && !isRightOnly {
                        if leftIsCanvas {
                            canvasPaneStack(width: leftWidth, dockEdge: .leading)
                        } else {
                            notePaneStack(width: leftWidth, dockEdge: .leading)
                        }
                    }

                    if !isLeftOnly {
                        if leftIsCanvas {
                            notePaneStack(width: rightWidth, dockEdge: .trailing)
                        } else {
                            canvasPaneStack(width: rightWidth, dockEdge: .trailing)
                        }
                    }
                }

                if isRightOnly {
                    let hiddenIsCanvas = leftIsCanvas
                    SplitRevealButton(systemImage: hiddenIsCanvas ? "square.grid.2x2" : "doc.text",
                                      accessibilityLabel: hiddenIsCanvas ? "캔버스 펼치기" : "노트 펼치기") {
                        revealSplit()
                    }
                    .position(x: dividerHitWidth * 0.5, y: geo.size.height * 0.5)
                } else if isLeftOnly {
                    let hiddenIsCanvas = !leftIsCanvas
                    SplitRevealButton(systemImage: hiddenIsCanvas ? "square.grid.2x2" : "doc.text",
                                      accessibilityLabel: hiddenIsCanvas ? "캔버스 펼치기" : "노트 펼치기") {
                        revealSplit()
                    }
                    .position(x: totalWidth - dividerHitWidth * 0.5,
                              y: geo.size.height * 0.5)
                } else if hasLeftPaneContent && !showDividerActions {
                    DividerHandle(visualWidth: dividerVisualWidth,
                                  hitWidth: dividerHitWidth)
                        .frame(width: dividerHitWidth)
                        .gesture(dividerDrag(totalWidth: totalWidth))
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                withAnimation(Motion.indirect) {
                                    showDividerActions = true
                                }
                            }
                        )
                        .position(x: dividerCenterX, y: geo.size.height * 0.5)
                        .transition(.opacity)
                }

                if hasLeftPaneContent && showDividerActions && !isLeftOnly && !isRightOnly {
                    DividerActionsBubble(
                        onSwap: { swapPanes() },
                        onMaximizeLeft: { maximizeSide(.leading) },
                        onMaximizeRight: { maximizeSide(.trailing) }
                    )
                    .position(x: dividerCenterX, y: geo.size.height * 0.5)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .center)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.4, anchor: .center)
                            .combined(with: .opacity)
                    ))
                }
            }
        }
    }

    @ViewBuilder
    private func notePaneStack(width: CGFloat, dockEdge: Edge) -> some View {
        ZStack(alignment: dockEdge == .leading ? .leading : .trailing) {
            leftPane
            sideDock(palette: palettePDF, edge: dockEdge)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func canvasPaneStack(width: CGFloat, dockEdge: Edge) -> some View {
        ZStack(alignment: dockEdge == .leading ? .leading : .trailing) {
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

            sideDock(palette: paletteCanvas, edge: dockEdge)
        }
        .frame(width: width)
    }

    private func swapPanes() {
        withAnimation(Motion.indirect) {
            isCanvasOnLeft.toggle()
            leftFraction = 1 - leftFraction
            showDividerActions = false
        }
    }

    private func maximizeSide(_ edge: Edge) {
        withAnimation(Motion.indirect) {
            leftFraction = edge == .leading ? 1 : 0
            showDividerActions = false
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
            activeNotePaperID: activeNotePaperID,
            activeCanvasPaperID: activeCanvasPaperID,
            documents: switchablePapers,
            documentSwitcherKind: documentSwitcherKind,
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
            onSelectDocument: switchToPaper,
            onCreateNote: { style in createDocument(of: .note, noteStyle: style) },
            onCreateCanvas: { background in createDocument(of: .canvas, canvasBackground: background) },
            canvasBackground: canvasBackground,
            onPickCanvasBackground: { type in
                guard let canvas = activeCanvasPaper else { return }
                canvas.canvasBackgroundRaw = type.rawValue
                canvas.updatedAt = .now
                scheduleSave()
            },
            isBlankPagedNote: isBlankPagedNote,
            notePageStyle: activeNotePaper?.notePageStyle ?? .lined,
            notePageCount: max(1, activeNotePaper?.notePageCount ?? 1),
            onAddNotePage: addBlankNotePage,
            onPickNotePageStyle: setBlankNotePageStyle,
            debugActions: debugActions,
            isCanvasOnLeft: isCanvasOnLeft && hasLeftPaneContent
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
        .chromeGlassRect(cornerRadius: Radius.xl)
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
        if isBlankPagedNote, let note = activeNotePaper {
            PageNoteView(
                drawing: $blankNoteDrawing,
                pageStyle: note.notePageStyle,
                pageCount: max(1, note.notePageCount),
                pageSize: CGSize(width: note.notePageWidth,
                                 height: note.notePageHeight),
                palette: palettePDF,
                isSplitResizing: dividerDragStartFraction != nil,
                onPageNoteActivated: {
                    activeInputSurface = .note
                },
                onStrokeBegan: {
                    activeInputSurface = .note
                    palettePDF.isStrokeInProgress = true
                },
                onStrokeEnded: {
                    palettePDF.isStrokeInProgress = false
                },
                onPencilTap: handlePencilTap,
                onAddPageRequested: addBlankNotePage
            )
        } else if let pdfDocument {
            PDFKitView(document: pdfDocument,
                       currentPageIndex: $currentPageIndex,
                       navigationTarget: $navigationTarget,
                       pageInkStrokes: $pdfInkStrokes,
                       palette: palettePDF,
                       textHighlights: activeNotePaper?.textHighlights ?? [],
                       regionMarks: activeNotePaper?.regionMarks ?? [],
                       onRegionCaptured: handleRegionCaptured,
                       onTextHighlightCreated: handleTextHighlightCreated,
                       onAnchorTapped: handleAnchorTapped,
                       onAnchorDragRequested: anchorDragItems,
                       onAnchorAddToCanvas: handleAnchorAddToCanvas,
                       onAnchorViewInCanvas: handleAnchorTapped,
                       onAnchorRecolor: handleAnchorRecolor,
                       onAnchorCopyText: handleAnchorCopyText,
                       onAnchorDelete: handleAnchorDelete,
                       onAnchorHasLinkedScrap: anchorHasLinkedScrap,
                       onPDFInkActivated: {
                           activeInputSurface = .note
                       },
                       onPencilTap: handlePencilTap,
                       onNavigationArrival: handleNavigationArrival)
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

    private func handleScrapTap(_ id: UUID, scrapWindowRect: CGRect) {
        guard let scrap = (activeCanvasPaper?.scrapItems ?? []).first(where: { $0.id == id }) else { return }
        let rect = CGRect(x: scrap.sourceRectX,
                          y: scrap.sourceRectY,
                          width: scrap.sourceRectW,
                          height: scrap.sourceRectH)
        if scrap.kind == .text, rect.isEmpty, scrap.anchorID == nil {
            beginEditingTextNote(id)
            return
        }
        pendingArrowSource = scrapWindowRect.isEmpty ? nil : scrapWindowRect
        jumpToSource(scrap: scrap)
    }

    private func jumpToSource(scrap: ScrapItem) {
        let pageRect = CGRect(x: scrap.sourceRectX,
                              y: scrap.sourceRectY,
                              width: scrap.sourceRectW,
                              height: scrap.sourceRectH)
        let pageIndex = scrap.sourcePageIndex
        let targetPaperID = findAnchorPaperID(for: scrap)
        if let targetID = targetPaperID, targetID != activeNotePaperID,
           let targetPaper = libraryPapers.first(where: { $0.id == targetID }) {
            // Temporarily swap the note pane to the anchor's source paper.
            // Once a tab system lands this branch becomes openInNewTab(...).
            switchToPaper(targetPaper)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                navigationTarget = PDFNavigationTarget(pageIndex: pageIndex,
                                                      pageRect: pageRect)
            }
        } else {
            navigationTarget = PDFNavigationTarget(pageIndex: pageIndex,
                                                  pageRect: pageRect)
        }
    }

    private func handleNavigationArrival(targetWindowRect: CGRect) {
        guard let source = pendingArrowSource else { return }
        pendingArrowSource = nil
        let arrow = NavigationArrow(id: UUID(),
                                    sourceWindowRect: source,
                                    targetWindowRect: targetWindowRect)
        navigationArrow = arrow
        let arrowID = arrow.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if navigationArrow?.id == arrowID {
                navigationArrow = nil
            }
        }
    }

    private func findAnchorPaperID(for scrap: ScrapItem) -> UUID? {
        guard let kind = scrap.anchorKind, let id = scrap.anchorID else {
            // No anchor — assume the source is the active note paper.
            return activeNotePaperID
        }
        switch kind {
        case .text:
            for paper in libraryPapers {
                if paper.textHighlights.contains(where: { $0.id == id }) {
                    return paper.id
                }
            }
        case .region:
            for paper in libraryPapers {
                if paper.regionMarks.contains(where: { $0.id == id }) {
                    return paper.id
                }
            }
        }
        return nil
    }

    private func handleAnchorTapped(_ anchor: AnchorRef) {
        let matchingScraps = libraryPapers
            .flatMap { $0.scrapItems }
            .filter { $0.anchorID == anchor.id }
        if matchingScraps.isEmpty { return }
        let sorted = matchingScraps.sorted { $0.createdAt < $1.createdAt }
        if let first = sorted.first {
            centerCanvasOn(scrap: first)
        }
        if sorted.count > 1 {
            anchorScrapListAnchor = anchor
            anchorScrapListItems = sorted
        }
    }

    private func anchorHasLinkedScrap(_ anchor: AnchorRef) -> Bool {
        libraryPapers.flatMap(\.scrapItems).contains { $0.anchorID == anchor.id }
    }

    private func handleAnchorAddToCanvas(_ anchor: AnchorRef) {
        guard let note = activeNotePaper,
              let pdfDocument = pdfDocument,
              anchor.pageIndex >= 0,
              anchor.pageIndex < pdfDocument.pageCount,
              let page = pdfDocument.page(at: anchor.pageIndex) else { return }
        let position = CGPoint(x: contentOffset.x + 120, y: contentOffset.y + 120)
        switch anchor.kind {
        case .text:
            guard let highlight = note.textHighlights.first(where: { $0.id == anchor.id }) else { return }
            let selection = selectionFromQuads(highlight.quadPoints, on: page)
            let text = selection?.string ?? ""
            guard !text.isEmpty else { return }
            let scrap = ScrapItem(
                kind: .text,
                text: text,
                position: position,
                size: estimateTextNoteSize(for: text),
                sourcePageIndex: highlight.pageIndex,
                sourceRect: highlight.boundingPageRect,
                anchorKind: .text,
                anchorID: highlight.id
            )
            scrap.document = activeCanvasPaper
            modelContext.insert(scrap)
        case .region:
            guard let mark = note.regionMarks.first(where: { $0.id == anchor.id }) else { return }
            let image = MarkerGestureController.renderPDFRegion(page: page,
                                                                 rect: mark.pageRect,
                                                                 scale: 2.0)
            guard let data = image.pngData() else { return }
            let scrap = ScrapItem(
                kind: .image,
                imageData: data,
                position: position,
                size: imageDisplaySize(for: image),
                sourcePageIndex: mark.pageIndex,
                sourceRect: mark.pageRect,
                anchorKind: .region,
                anchorID: mark.id
            )
            scrap.document = activeCanvasPaper
            modelContext.insert(scrap)
        }
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
    }

    private func handleAnchorRecolor(_ anchor: AnchorRef, _ hex: String) {
        guard let note = activeNotePaper else { return }
        switch anchor.kind {
        case .text:
            if let highlight = note.textHighlights.first(where: { $0.id == anchor.id }) {
                highlight.colorHex = hex
            }
        case .region:
            if let mark = note.regionMarks.first(where: { $0.id == anchor.id }) {
                mark.colorHex = hex
            }
        }
        note.updatedAt = .now
        scheduleSave()
    }

    private func handleAnchorCopyText(_ anchor: AnchorRef) {
        guard anchor.kind == .text,
              let note = activeNotePaper,
              let pdfDocument = pdfDocument,
              anchor.pageIndex >= 0,
              anchor.pageIndex < pdfDocument.pageCount,
              let page = pdfDocument.page(at: anchor.pageIndex),
              let highlight = note.textHighlights.first(where: { $0.id == anchor.id }),
              let selection = selectionFromQuads(highlight.quadPoints, on: page) else { return }
        let text = selection.string ?? ""
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    private func handleAnchorDelete(_ anchor: AnchorRef) {
        switch anchor.kind {
        case .text:
            requestDeletion(.textHighlight(anchor.id))
        case .region:
            requestDeletion(.regionMark(anchor.id))
        }
    }

    private func centerCanvasOn(scrap: ScrapItem) {
        // If the scrap belongs to a different canvas paper, switch canvas pane
        // first (mirroring the cross-paper note jump).
        if let parent = scrap.document, parent.id != activeCanvasPaperID {
            switchToPaper(parent)
        }
        // Pan the canvas so the scrap is centered.
        let target = CGPoint(
            x: max(0, CGFloat(scrap.positionX) + CGFloat(scrap.width) / 2 - 200),
            y: max(0, CGFloat(scrap.positionY) + CGFloat(scrap.height) / 2 - 200)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            contentOffset = target
        }
    }

    private func anchorDragItems(_ anchor: AnchorRef) -> [UIDragItem] {
        guard let note = activeNotePaper,
              note.id == activeNotePaperID,
              let pdfDocument = pdfDocument,
              anchor.pageIndex >= 0,
              anchor.pageIndex < pdfDocument.pageCount,
              let page = pdfDocument.page(at: anchor.pageIndex) else { return [] }
        switch anchor.kind {
        case .text:
            guard let highlight = note.textHighlights.first(where: { $0.id == anchor.id }) else { return [] }
            let selection = selectionFromQuads(highlight.quadPoints, on: page)
            let text = selection?.string ?? ""
            guard !text.isEmpty else { return [] }
            let payload = AnchorDragPayload(
                anchorKind: .text,
                anchorID: highlight.id,
                scrapKind: .text,
                text: text,
                imageData: nil,
                pageIndex: highlight.pageIndex,
                pageRect: highlight.boundingPageRect
            )
            let provider = NSItemProvider(object: text as NSString)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = payload
            return [item]
        case .region:
            guard let mark = note.regionMarks.first(where: { $0.id == anchor.id }) else { return [] }
            let image = MarkerGestureController.renderPDFRegion(page: page,
                                                                rect: mark.pageRect,
                                                                scale: 2.0)
            guard let data = image.pngData() else { return [] }
            let payload = AnchorDragPayload(
                anchorKind: .region,
                anchorID: mark.id,
                scrapKind: .image,
                text: nil,
                imageData: data,
                pageIndex: mark.pageIndex,
                pageRect: mark.pageRect
            )
            let provider = NSItemProvider(object: image)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = payload
            return [item]
        }
    }

    private func selectionFromQuads(_ quads: [CGRect], on page: PDFPage) -> PDFSelection? {
        guard let first = quads.first, let last = quads.last else { return nil }
        let topLeft = CGPoint(x: first.minX + 1, y: first.midY)
        let bottomRight = CGPoint(x: last.maxX - 1, y: last.midY)
        return page.selection(from: topLeft, to: bottomRight)
    }

    private func handleRegionCaptured(pageIndex: Int, pageRect: CGRect, image: UIImage) {
        guard let note = activeNotePaper else { return }
        let colorHex = AnchorColor.hex(from: UIColor(palettePDF.color).cgColor)
        let mark = PDFRegionMark(pageIndex: pageIndex,
                                 rect: pageRect,
                                 colorHex: colorHex)
        mark.document = note
        modelContext.insert(mark)
        note.updatedAt = .now
        scheduleSave()
    }

    private func handleTextHighlightCreated(pageIndex: Int,
                                            quadPoints: [CGRect],
                                            colorHex: String) {
        guard let note = activeNotePaper else { return }
        let highlight = PDFTextHighlight(pageIndex: pageIndex,
                                         quadPoints: quadPoints,
                                         colorHex: colorHex)
        highlight.document = note
        modelContext.insert(highlight)
        note.updatedAt = .now
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
        if scrap.anchorID != nil {
            requestDeletion(.scrap(scrap))
            return
        }
        modelContext.delete(scrap)
        activeCanvasPaper?.updatedAt = .now
        scheduleSave()
    }

    private var anchorScrapDeletionMode: AnchorDeletionMode {
        AnchorDeletionMode(rawValue: anchorScrapDeletionModeRaw) ?? .ask
    }

    private func requestDeletion(_ target: PendingAnchorDeletion.Target) {
        let mode = anchorScrapDeletionMode
        switch mode {
        case .independent:
            performDeletion(target: target, cascade: false)
        case .cascade:
            performDeletion(target: target, cascade: true)
        case .ask:
            pendingDeletion = PendingAnchorDeletion(target: target, rememberChoice: true)
        }
    }

    private func performDeletion(target: PendingAnchorDeletion.Target, cascade: Bool) {
        switch target {
        case .scrap(let scrap):
            if cascade, let kind = scrap.anchorKind, let aid = scrap.anchorID {
                deleteAnchor(kind: kind, id: aid)
            }
            modelContext.delete(scrap)
            scrap.document?.updatedAt = .now
        case .textHighlight(let id):
            if cascade {
                deleteScrapsAttachedTo(anchorID: id)
            }
            if let highlight = activeNotePaper?.textHighlights.first(where: { $0.id == id }) {
                modelContext.delete(highlight)
                activeNotePaper?.updatedAt = .now
            }
        case .regionMark(let id):
            if cascade {
                deleteScrapsAttachedTo(anchorID: id)
            }
            if let mark = activeNotePaper?.regionMarks.first(where: { $0.id == id }) {
                modelContext.delete(mark)
                activeNotePaper?.updatedAt = .now
            }
        }
        scheduleSave()
    }

    private func deleteAnchor(kind: PDFAnchorKind, id: UUID) {
        switch kind {
        case .text:
            if let highlight = libraryPapers.flatMap(\.textHighlights).first(where: { $0.id == id }) {
                modelContext.delete(highlight)
            }
        case .region:
            if let mark = libraryPapers.flatMap(\.regionMarks).first(where: { $0.id == id }) {
                modelContext.delete(mark)
            }
        }
    }

    private func deleteScrapsAttachedTo(anchorID: UUID) {
        let scraps = libraryPapers.flatMap(\.scrapItems).filter { $0.anchorID == anchorID }
        for scrap in scraps {
            modelContext.delete(scrap)
            scrap.document?.updatedAt = .now
        }
    }

    private func handleCanvasDrop(_ payload: CanvasDropPayload) {
        guard let canvas = activeCanvasPaper else { return }
        let size = estimateScrapSize(for: payload)
        // Center the new scrap on the drop point so the finger lands roughly
        // mid-card instead of at the top-left corner.
        let centered = CGPoint(
            x: payload.position.x - size.width / 2,
            y: payload.position.y - size.height / 2
        )
        let scrap = ScrapItem(
            kind: payload.kind,
            text: payload.text,
            imageData: payload.imageData,
            position: centered,
            size: size,
            sourcePageIndex: payload.sourcePageIndex,
            sourceRect: payload.sourceRect,
            anchorKind: payload.anchorKind,
            anchorID: payload.anchorID
        )
        scrap.document = canvas
        modelContext.insert(scrap)
        canvas.updatedAt = .now
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
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dividerDragStartFraction == nil {
                    dividerDragStartFraction = leftFraction
                }
                let baseFraction = dividerDragStartFraction ?? leftFraction
                let baseWidth = totalWidth * baseFraction
                let proposed = (baseWidth + value.translation.width) / totalWidth
                leftFraction = liveSplitFraction(for: proposed)
            }
            .onEnded { value in
                let baseFraction = dividerDragStartFraction ?? leftFraction
                let baseWidth = totalWidth * baseFraction
                let proposed = (baseWidth + value.translation.width) / totalWidth
                leftFraction = snappedSplitFraction(for: proposed)
                dividerDragStartFraction = nil
            }
    }

    private func liveSplitFraction(for proposed: CGFloat) -> CGFloat {
        max(0, min(1, proposed))
    }

    private func snappedSplitFraction(for proposed: CGFloat) -> CGFloat {
        if proposed <= splitOnlySnapFraction { return 0 }
        if proposed >= 1 - splitOnlySnapFraction { return 1 }
        return max(minFraction, min(maxFraction, proposed))
    }

    private func revealSplit() {
        withAnimation(Motion.indirect) {
            leftFraction = 0.5
        }
    }

    private func toggleDocumentSwitcher(_ kind: PaperDocumentKind) {
        // Spring is required so that matchedGeometryEffect interpolation between
        // the title capsule and the expanded panel is actually visible — a 180ms
        // easeInOut completes before the user can perceive the morph.
        withAnimation(Motion.indirect) {
            documentSwitcherKind = documentSwitcherKind == kind ? nil : kind
        }
    }

    private func createDocument(of kind: PaperDocumentKind,
                                noteStyle: NotePageStyle = .lined,
                                canvasBackground: CanvasBackground = .dots) {
        let title = nextBlankTitle(for: kind)
        let newPaper = PaperDocument(title: title,
                                     kind: kind,
                                     notePageStyle: noteStyle,
                                     canvasBackground: canvasBackground)
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
                withAnimation(Motion.indirect) { documentSwitcherKind = nil }
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
            withAnimation(Motion.indirect) {
                activeNotePaperID = target.id
                documentSwitcherKind = nil
            }
        case .canvas:
            guard target.id != activeCanvasPaperID else {
                withAnimation(Motion.indirect) { documentSwitcherKind = nil }
                return
            }
            saveTask?.cancel()
            savedStatusResetTask?.cancel()
            if didLoadCanvas { persistCanvas() }
            resetCanvasPane()
            target.companionPaperID = activeNotePaperID
            target.updatedAt = .now
            withAnimation(Motion.indirect) {
                activeCanvasPaperID = target.id
                documentSwitcherKind = nil
            }
        }
    }

    private func resetNotePane() {
        pdfDocument = nil
        pdfInkStrokes = [:]
        blankNoteDrawing = PKDrawing()
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
            // Blank, page-based note — restore the persisted PencilKit drawing.
            if let data = note.drawingData,
               !data.isEmpty,
               let restored = try? PKDrawing(data: data) {
                blankNoteDrawing = restored
            } else {
                blankNoteDrawing = PKDrawing()
            }
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
        if note.isBlankPagedNote {
            note.drawingData = blankNoteDrawing.dataRepresentation()
        }
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

    private func addBlankNotePage() {
        guard let note = activeNotePaper, note.isBlankPagedNote else { return }
        note.notePageCount = max(1, note.notePageCount) + 1
        note.updatedAt = .now
        scheduleSave()
    }

    private func setBlankNotePageStyle(_ style: NotePageStyle) {
        guard let note = activeNotePaper, note.isBlankPagedNote else { return }
        note.notePageStyle = style
        note.updatedAt = .now
        scheduleSave()
    }

    private func handleDisappear() {
        saveTask?.cancel()
        savedStatusResetTask?.cancel()
        persistAll()
        accessingURL?.stopAccessingSecurityScopedResource()
        accessingURL = nil
    }
}

enum AnchorDeletionMode: String {
    case independent
    case cascade
    case ask
}

struct PendingAnchorDeletion: Identifiable {
    enum Target {
        case scrap(ScrapItem)
        case textHighlight(UUID)
        case regionMark(UUID)
    }
    let id = UUID()
    let target: Target
    var rememberChoice: Bool
}

struct AnchorScrapsSheet: View {
    let anchor: AnchorRef
    let scraps: [ScrapItem]
    let onSelect: (ScrapItem) -> Void
    let onDelete: (ScrapItem) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scraps, id: \.id) { scrap in
                        Button {
                            onSelect(scrap)
                        } label: {
                            HStack(spacing: 12) {
                                anchorPreview(for: scrap)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label(for: scrap))
                                        .font(.body)
                                        .foregroundStyle(Color.Ink.primary)
                                        .lineLimit(2)
                                    Text(scrap.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Color.Ink.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                onDelete(scrap)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("연결된 노드 \(scraps.count)개")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(anchor.kind == .text ? "텍스트 하이라이트" : "영역")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기", action: onClose)
                }
            }
        }
    }

    private func label(for scrap: ScrapItem) -> String {
        switch scrap.kind {
        case .text:
            return scrap.text?.replacingOccurrences(of: "\n", with: " ") ?? "(빈 노드)"
        case .image:
            return "이미지 노드"
        }
    }

    @ViewBuilder
    private func anchorPreview(for scrap: ScrapItem) -> some View {
        switch scrap.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.Ink.secondary)
                .frame(width: 44, height: 44)
                .background(Color.Surface.fill, in: RoundedRectangle(cornerRadius: 8))
        case .image:
            if let data = scrap.imageData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .frame(width: 44, height: 44)
                    .background(Color.Surface.fill, in: RoundedRectangle(cornerRadius: 8))
            }
        }
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

private struct DividerActionsBubble: View {
    let onSwap: () -> Void
    let onMaximizeLeft: () -> Void
    let onMaximizeRight: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            BubbleActionButton(
                systemImage: "rectangle.lefthalf.inset.filled",
                accessibilityLabel: "좌측 최대화",
                action: onMaximizeLeft
            )
            Rectangle()
                .fill(Color.Rule.hairline)
                .frame(width: 24, height: 0.5)
            BubbleActionButton(
                systemImage: "arrow.left.arrow.right",
                accessibilityLabel: "좌우 교체",
                action: onSwap
            )
            Rectangle()
                .fill(Color.Rule.hairline)
                .frame(width: 24, height: 0.5)
            BubbleActionButton(
                systemImage: "rectangle.righthalf.inset.filled",
                accessibilityLabel: "우측 최대화",
                action: onMaximizeRight
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .chromeGlassRect(cornerRadius: 24)
        .fixedSize()
    }
}

private struct BubbleActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.Ink.primary)
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SplitRevealButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Ink.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .chromeGlassCapsule()
        .contentShape(.rect)
        .hoverEffect(.lift)
        .accessibilityLabel(accessibilityLabel)
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
