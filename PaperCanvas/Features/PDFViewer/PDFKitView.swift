import SwiftUI
import PDFKit
import UIKit

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var navigationTarget: PDFNavigationTarget?
    @Binding var pageInkStrokes: [Int: [InkStroke]]
    let palette: PaletteState
    var textHighlights: [PDFTextHighlight] = []
    var regionMarks: [PDFRegionMark] = []
    var onRegionCaptured: ((Int, CGRect, UIImage) -> Void)? = nil
    var onTextHighlightCreated: ((Int, [CGRect], String) -> Void)? = nil
    var onAnchorTapped: ((AnchorRef) -> Void)? = nil
    var onAnchorDragRequested: ((AnchorRef) -> [UIDragItem])? = nil
    var onAnchorAddToCanvas: ((AnchorRef) -> Void)? = nil
    var onAnchorViewInCanvas: ((AnchorRef) -> Void)? = nil
    var onAnchorRecolor: ((AnchorRef, String) -> Void)? = nil
    var onAnchorCopyText: ((AnchorRef) -> Void)? = nil
    var onAnchorDelete: ((AnchorRef) -> Void)? = nil
    var onAnchorHasLinkedScrap: ((AnchorRef) -> Bool)? = nil
    var onPDFInkActivated: (() -> Void)? = nil
    var onPencilTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .secondarySystemBackground
        wrapper.clipsToBounds = true

        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(false)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.isInMarkupMode = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.addInteraction(UIDragInteraction(delegate: context.coordinator))
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        pdfView.addInteraction(pencilInteraction)
        let hoverIndicatorView = PencilHoverIndicatorView()
        hoverIndicatorView.isUserInteractionEnabled = false

        let pencilInput = PDFPencilInputGestureRecognizer()
        pdfView.addGestureRecognizer(pencilInput)

        wrapper.addSubview(pdfView)
        wrapper.addSubview(hoverIndicatorView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        context.coordinator.attach(wrapper: wrapper,
                                   pdfView: pdfView,
                                   hoverIndicatorView: hoverIndicatorView,
                                   pencilInput: pencilInput)
        pdfView.document = document

        let marker = MarkerGestureController(pdfView: pdfView, palette: palette)
        marker.onRegionCaptured = { [weak coord = context.coordinator] pageIdx, rect, img in
            coord?.parent.onRegionCaptured?(pageIdx, rect, img)
        }
        marker.onMarqueeBegan = { [weak coord = context.coordinator] in
            coord?.handleMarqueeBegan()
        }
        context.coordinator.markerGesture = marker

        let liveHighlight = LiveHighlightOverlay(frame: pdfView.bounds)
        liveHighlight.pdfView = pdfView
        liveHighlight.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.addSubview(liveHighlight)
        context.coordinator.liveHighlightOverlay = liveHighlight

        let anchorOverlay = PDFAnchorOverlay(pdfView: pdfView)
        anchorOverlay.delegate = context.coordinator
        pdfView.addSubview(anchorOverlay)
        anchorOverlay.frame = pdfView.bounds
        context.coordinator.anchorOverlay = anchorOverlay

        DispatchQueue.main.async {
            if let page = document.page(at: currentPageIndex) {
                pdfView.go(to: page)
            }
            pdfView.layoutDocumentView()
            context.coordinator.rebuildRenderedInk()
            context.coordinator.syncAnchorOverlay()
        }
        return wrapper
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        guard let pdfView = context.coordinator.hostPDFView else { return }
        if pdfView.document !== document {
            context.coordinator.clearTransientState()
            pdfView.document = document
            DispatchQueue.main.async {
                if let page = document.page(at: currentPageIndex) {
                    pdfView.go(to: page)
                } else {
                    pdfView.goToFirstPage(nil)
                }
                pdfView.layoutDocumentView()
                context.coordinator.rebuildRenderedInk()
            }
        }

        if let target = navigationTarget, context.coordinator.lastConsumedTargetID != target.id {
            context.coordinator.lastConsumedTargetID = target.id
            context.coordinator.scroll(to: target, in: pdfView)
            DispatchQueue.main.async {
                self.navigationTarget = nil
            }
        }

        context.coordinator.syncExternalStrokesIfNeeded()
        context.coordinator.handleUndoRedoIfNeeded()
        context.coordinator.syncAnchorOverlay()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIDragInteractionDelegate, UIPencilInteractionDelegate, @preconcurrency PDFPageOverlayViewProvider, PDFAnchorOverlayDelegate {
        var parent: PDFKitView
        var lastConsumedTargetID: UUID?
        var markerGesture: MarkerGestureController?
        weak var anchorOverlay: PDFAnchorOverlay?
        weak var liveHighlightOverlay: LiveHighlightOverlay?

        // Text-highlight mode (marker tool, drag-from-text)
        private var activeHighlightPageIndex: Int?
        private var activeHighlightStartPagePoint: CGPoint?
        private var activeHighlightQuads: [CGRect] = []

        private weak var wrapper: UIView?
        weak var hostPDFView: PDFView?
        private weak var hoverIndicatorView: PencilHoverIndicatorView?
        private weak var pencilInput: PDFPencilInputGestureRecognizer?
        private weak var internalScrollView: UIScrollView?

        private var pageObserver: NSObjectProtocol?
        private var scaleObserver: NSObjectProtocol?
        private var visiblePagesObserver: NSObjectProtocol?
        private var scrollObservations: [NSKeyValueObservation] = []
        private var displayLink: CADisplayLink?
        private var lastViewportKey = ""
        private var lastStrokeSignature = ""
        private var pageRenderViews: [Int: PDFInkPageRenderView] = [:]

        private var lastActivePageIndex: Int?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?
        private var undoStack: [PDFInkUndoAction] = []
        private var redoStack: [PDFInkUndoAction] = []

        private var activePageIndex: Int?
        private var activeStroke: InkStroke?
        private var activeStrokeStartTime: TimeInterval?
        private var activeEraserOriginalStrokes: [InkStroke]?
        private var selectedStrokeIDsByPage: [Int: Set<UUID>] = [:]
        private var activeLassoPageIndex: Int?
        private var activeLassoMode: LassoMode?
        private var activeLassoPoints: [InkPoint] = []
        private var movingSelectionPageIndex: Int?
        private var movingSelectionOriginalStrokes: [InkStroke]?
        private var movingSelectionLastPoint: CGPoint?
        private var movingSelectionStartPoint: CGPoint?
        private var movingSelectionStartTime: TimeInterval?
        private var movingSelectionDidExceedTapThreshold: Bool = false
        private var lastSelectionMenuPageIndex: Int?

        init(_ parent: PDFKitView) { self.parent = parent }

        fileprivate func attach(wrapper: UIView,
                                pdfView: PDFView,
                                hoverIndicatorView: PencilHoverIndicatorView,
                                pencilInput: PDFPencilInputGestureRecognizer) {
            self.wrapper = wrapper
            self.hostPDFView = pdfView
            self.hoverIndicatorView = hoverIndicatorView
            self.pencilInput = pencilInput
            pdfView.pageOverlayViewProvider = self
            pencilInput.onTouches = { [weak self] phase, touches, event in
                self?.handlePencilInput(phase: phase, touches: touches, event: event)
            }

            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.syncPageIndex()
                    self?.rebuildRenderedInk()
                }
            }
            scaleObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.rebuildRenderedInk()
                    self?.refreshHoverIndicator()
                }
            }
            visiblePagesObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewVisiblePagesChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.rebuildRenderedInk()
                }
            }

            if #available(iOS 16.1, *) {
                let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
                wrapper.addGestureRecognizer(hover)
            }
            startDisplayLink()
            DispatchQueue.main.async { [weak self] in
                self?.attachScrollObservers()
                pdfView.layoutDocumentView()
                self?.rebuildRenderedInk()
            }
        }

        func detach() {
            stopDisplayLink()
            detachScrollObservers()
            hostPDFView?.pageOverlayViewProvider = nil
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
            if let visiblePagesObserver { NotificationCenter.default.removeObserver(visiblePagesObserver) }
            pageObserver = nil
            scaleObserver = nil
            visiblePagesObserver = nil
            pencilInput?.onTouches = nil
            hoverIndicatorView?.hide()
            clearTransientState()
            pageRenderViews.removeAll()
        }

        func clearTransientState() {
            lastViewportKey = ""
            lastStrokeSignature = ""
            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = nil
            activeEraserOriginalStrokes = nil
            selectedStrokeIDsByPage.removeAll()
            clearActiveLassoState()
            lastActivePageIndex = nil
            undoStack.removeAll()
            redoStack.removeAll()
            publishPDFUndoRedoState(canUndo: false, canRedo: false)
            pageRenderViews.values.forEach { $0.clear() }
            pageRenderViews.removeAll()
        }

        func syncExternalStrokesIfNeeded() {
            let signature = strokeSignature(for: parent.pageInkStrokes)
            guard signature != lastStrokeSignature else { return }
            lastStrokeSignature = signature
            rebuildRenderedInk()
            updateUndoRedoState()
        }

        private func syncPageIndex() {
            guard let hostPDFView,
                  let document = hostPDFView.document,
                  let page = hostPDFView.currentPage else { return }
            let idx = document.index(for: page)
            if idx >= 0, parent.currentPageIndex != idx {
                parent.currentPageIndex = idx
            }
        }

        // MARK: - Pencil input

        private func handlePencilInput(phase: PDFPencilInputPhase,
                                       touches: [UITouch],
                                       event: UIEvent?) {
            if parent.palette.tool == .lasso {
                handleLassoInput(phase: phase, touches: touches)
                return
            }
            if parent.palette.tool == .marker {
                handleMarkerInput(phase: phase, touches: touches)
                return
            }
            switch phase {
            case .began:
                beginStroke(with: touches)
            case .moved:
                appendTouchesToActiveStroke(touches)
            case .ended:
                appendTouchesToActiveStroke(touches)
                finishActiveStroke()
            case .cancelled:
                cancelActiveStroke()
            }
        }

        // MARK: - Marker (scrap) input

        private func handleMarkerInput(phase: PDFPencilInputPhase, touches: [UITouch]) {
            let submode = parent.palette.markerSubmode
            switch phase {
            case .began:
                if submode.highlightEnabled,
                   let pdfView = hostPDFView,
                   let touch = touches.first,
                   let document = pdfView.document {
                    let location = touch.preciseLocation(in: pdfView)
                    if let page = pdfView.page(for: location, nearest: false) {
                        let pagePoint = pdfView.convert(location, to: page)
                        if page.characterIndex(at: pagePoint) >= 0 {
                            activeHighlightPageIndex = document.index(for: page)
                            activeHighlightStartPagePoint = pagePoint
                            activeHighlightQuads = []
                            pdfView.currentSelection = nil
                            updateLiveHighlight()
                            parent.palette.isStrokeInProgress = true
                            return
                        }
                    }
                }
                if submode.inkEnabled {
                    beginStroke(with: touches)
                }
            case .moved:
                if let pageIndex = activeHighlightPageIndex,
                   let start = activeHighlightStartPagePoint,
                   let pdfView = hostPDFView,
                   let document = pdfView.document,
                   let page = document.page(at: pageIndex),
                   let touch = touches.first {
                    let location = touch.preciseLocation(in: pdfView)
                    let endPagePoint = pdfView.convert(location, to: page)
                    if let selection = page.selection(from: start, to: endPagePoint) {
                        activeHighlightQuads = selection.selectionsByLine().compactMap { lineSel in
                            let bounds = lineSel.bounds(for: page)
                            return bounds.width > 0.5 && bounds.height > 0.5 ? bounds : nil
                        }
                    } else {
                        activeHighlightQuads = []
                    }
                    updateLiveHighlight()
                    return
                }
                if activeStroke != nil {
                    appendTouchesToActiveStroke(touches)
                }
            case .ended:
                if activeHighlightPageIndex != nil {
                    finalizeTextHighlight()
                    return
                }
                if activeStroke != nil {
                    appendTouchesToActiveStroke(touches)
                    finishActiveStroke()
                }
            case .cancelled:
                if activeHighlightPageIndex != nil {
                    cancelTextHighlight()
                    return
                }
                if activeStroke != nil {
                    cancelActiveStroke()
                }
            }
        }

        private func updateLiveHighlight() {
            guard let overlay = liveHighlightOverlay,
                  let pageIndex = activeHighlightPageIndex else { return }
            let color = UIColor(parent.palette.color)
            overlay.update(pageIndex: pageIndex,
                           pageRects: activeHighlightQuads,
                           color: color)
        }

        private func finalizeTextHighlight() {
            defer {
                activeHighlightPageIndex = nil
                activeHighlightStartPagePoint = nil
                activeHighlightQuads = []
                liveHighlightOverlay?.clear()
                parent.palette.isStrokeInProgress = false
            }
            guard let pageIndex = activeHighlightPageIndex else { return }
            let quads = activeHighlightQuads
            hostPDFView?.currentSelection = nil
            guard !quads.isEmpty else { return }
            let colorHex = AnchorColor.hex(from: UIColor(parent.palette.color).cgColor)
            parent.onTextHighlightCreated?(pageIndex, quads, colorHex)
        }

        private func cancelTextHighlight() {
            hostPDFView?.currentSelection = nil
            activeHighlightPageIndex = nil
            activeHighlightStartPagePoint = nil
            activeHighlightQuads = []
            liveHighlightOverlay?.clear()
            parent.palette.isStrokeInProgress = false
        }

        /// Called by MarkerGestureController the moment its long-press latches.
        /// We've now committed to region mode, so drop any in-progress text
        /// highlight or ink stroke that the pencil pipeline may have started.
        func handleMarqueeBegan() {
            if activeHighlightPageIndex != nil {
                cancelTextHighlight()
            }
            if activeStroke != nil {
                cancelActiveStroke()
            }
            hostPDFView?.currentSelection = nil
        }

        // MARK: - Anchor overlay

        func syncAnchorOverlay() {
            guard let overlay = anchorOverlay, let pdfView = hostPDFView else { return }
            overlay.frame = pdfView.bounds
            if let live = liveHighlightOverlay {
                live.frame = pdfView.bounds
                pdfView.bringSubviewToFront(live)
            }
            pdfView.bringSubviewToFront(overlay)
            overlay.sync(textHighlights: parent.textHighlights,
                         regionMarks: parent.regionMarks,
                         in: pdfView)
            overlay.relayoutForViewportChange()
        }

        // MARK: PDFAnchorOverlayDelegate

        func anchorOverlay(_ overlay: PDFAnchorOverlay,
                           didTap anchor: AnchorRef) {
            presentAnchorContextMenu(for: anchor)
        }

        private func presentAnchorContextMenu(for anchor: AnchorRef) {
            guard let wrapper,
                  let sourceRect = convertPageRectToWrapper(pageBounds: anchor.pageRect,
                                                             pageIndex: anchor.pageIndex) else { return }
            let actions = AnchorContextMenuActions(
                kind: anchor.kind,
                hasLinkedScrap: parent.onAnchorHasLinkedScrap?(anchor) ?? false,
                canCopyText: anchor.kind == .text,
                onAddToCanvas: { [weak self] in
                    self?.parent.onAnchorAddToCanvas?(anchor)
                },
                onViewInCanvas: { [weak self] in
                    self?.parent.onAnchorViewInCanvas?(anchor)
                },
                onCopyText: { [weak self] in
                    self?.parent.onAnchorCopyText?(anchor)
                },
                onRecolor: { [weak self] color in
                    let hex = AnchorColor.hex(from: UIColor(color).cgColor)
                    self?.parent.onAnchorRecolor?(anchor, hex)
                },
                onDelete: { [weak self] in
                    self?.parent.onAnchorDelete?(anchor)
                }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, let wrapper = self.wrapper else { return }
                AnchorContextMenu.shared.present(in: wrapper,
                                                  sourceRect: sourceRect,
                                                  actions: actions)
            }
        }

        func anchorOverlay(_ overlay: PDFAnchorOverlay,
                           dragItemsFor anchor: AnchorRef) -> [UIDragItem] {
            parent.onAnchorDragRequested?(anchor) ?? []
        }

        private func beginStroke(with touches: [UITouch]) {
            guard let touch = touches.first,
                  let sample = makeInkPoint(from: touch, startTime: touch.timestamp) else { return }
            activePageIndex = sample.pageIndex
            activeStrokeStartTime = touch.timestamp
            activatePDFInk(pageIndex: sample.pageIndex)
            parent.palette.isStrokeInProgress = true
            selectedStrokeIDsByPage.removeAll()
            clearActiveLassoState()
            hoverIndicatorView?.hide()

            activeStroke = InkStroke(
                tool: currentInkTool,
                color: currentInkColor,
                baseWidth: parent.palette.width,
                points: [sample.point]
            )
            if currentInkTool == .eraser {
                activeEraserOriginalStrokes = parent.pageInkStrokes[sample.pageIndex] ?? []
            } else {
                activeEraserOriginalStrokes = nil
            }
            updateUndoRedoState()
            rebuildRenderedInk()
        }

        private func appendTouchesToActiveStroke(_ touches: [UITouch]) {
            guard let pageIndex = activePageIndex,
                  let startTime = activeStrokeStartTime,
                  var stroke = activeStroke else { return }

            var didAppend = false
            for touch in touches {
                guard let sample = makeInkPoint(from: touch, startTime: startTime),
                      sample.pageIndex == pageIndex else { continue }
                if let last = stroke.points.last,
                   hypot(last.location.x - sample.point.location.x,
                         last.location.y - sample.point.location.y) < 0.35 {
                    continue
                }
                stroke.points.append(sample.point)
                didAppend = true
            }
            guard didAppend else { return }
            stroke.boundingBox = InkStroke.computeBoundingBox(
                for: stroke.points,
                baseWidth: stroke.baseWidth
            )
            activeStroke = stroke
            if stroke.tool == .eraser, parent.palette.eraserMode == .pixel {
                applyLivePixelErase(with: stroke, pageIndex: pageIndex)
            } else {
                rebuildRenderedInk()
            }
        }

        private func finishActiveStroke() {
            guard let pageIndex = activePageIndex,
                  let stroke = activeStroke,
                  !stroke.points.isEmpty else {
                cancelActiveStroke()
                return
            }

            switch stroke.tool {
            case .eraser:
                if parent.palette.eraserMode == .pixel {
                    applyLivePixelErase(with: stroke, pageIndex: pageIndex)
                    finishLivePixelErase(pageIndex: pageIndex)
                } else {
                    erase(with: stroke, pageIndex: pageIndex)
                }
            case .pen, .gelPen, .fountainPen, .brushPen, .pencil, .marker, .highlighter:
                appendCommittedStroke(stroke, pageIndex: pageIndex)
            }

            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = nil
            activeEraserOriginalStrokes = nil
            parent.palette.isStrokeInProgress = false
            rebuildRenderedInk()
        }

        private func cancelActiveStroke() {
            if let pageIndex = activePageIndex,
               let original = activeEraserOriginalStrokes,
               activeStroke?.tool == .eraser,
               parent.palette.eraserMode == .pixel {
                setStrokes(original, for: pageIndex)
            }
            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = nil
            activeEraserOriginalStrokes = nil
            parent.palette.isStrokeInProgress = false
            rebuildRenderedInk()
        }

        private func activatePDFInk(pageIndex: Int) {
            lastActivePageIndex = pageIndex
            parent.palette.lastActiveCanvas = .pdfInk
            parent.onPDFInkActivated?()
        }

        // MARK: - Lasso input

        private func handleLassoInput(phase: PDFPencilInputPhase, touches: [UITouch]) {
            switch phase {
            case .began:
                beginLasso(with: touches)
            case .moved:
                appendLassoTouches(touches)
            case .ended:
                appendLassoTouches(touches)
                finishLasso()
            case .cancelled:
                cancelLasso()
            }
        }

        private func beginLasso(with touches: [UITouch]) {
            guard let touch = touches.first,
                  let sample = makeInkPoint(from: touch, startTime: touch.timestamp) else { return }
            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = touch.timestamp
            activeEraserOriginalStrokes = nil
            activatePDFInk(pageIndex: sample.pageIndex)
            parent.palette.isStrokeInProgress = true
            hoverIndicatorView?.hide()

            if shouldMoveSelection(from: sample.point.location, pageIndex: sample.pageIndex) {
                movingSelectionPageIndex = sample.pageIndex
                movingSelectionOriginalStrokes = parent.pageInkStrokes[sample.pageIndex] ?? []
                movingSelectionLastPoint = sample.point.location
                movingSelectionStartPoint = sample.point.location
                movingSelectionStartTime = touch.timestamp
                movingSelectionDidExceedTapThreshold = false
                LassoSelectionMenu.shared.dismiss()
                activeLassoPageIndex = sample.pageIndex
                activeLassoMode = nil
                activeLassoPoints = []
            } else {
                LassoSelectionMenu.shared.dismiss()
                selectedStrokeIDsByPage.removeAll()
                activeLassoPageIndex = sample.pageIndex
                activeLassoMode = parent.palette.lassoMode
                activeLassoPoints = [sample.point]
                movingSelectionPageIndex = nil
                movingSelectionOriginalStrokes = nil
                movingSelectionLastPoint = nil
            }
            rebuildRenderedInk()
        }

        private func appendLassoTouches(_ touches: [UITouch]) {
            guard let touch = touches.first else { return }
            if let pageIndex = movingSelectionPageIndex,
               let startTime = activeStrokeStartTime ?? touches.first?.timestamp,
               let sample = makeInkPoint(from: touch, startTime: startTime),
               sample.pageIndex == pageIndex {
                moveSelectedStrokes(to: sample.point.location, pageIndex: pageIndex)
                return
            }

            guard let pageIndex = activeLassoPageIndex,
                  let startTime = activeStrokeStartTime ?? touches.first?.timestamp,
                  let sample = makeInkPoint(from: touch, startTime: startTime),
                  sample.pageIndex == pageIndex else { return }
            switch activeLassoMode {
            case .rectangle:
                if let first = activeLassoPoints.first {
                    activeLassoPoints = [first, sample.point]
                } else {
                    activeLassoPoints = [sample.point]
                }
            case .freeform:
                if let last = activeLassoPoints.last,
                   hypot(last.location.x - sample.point.location.x,
                         last.location.y - sample.point.location.y) < 0.35 {
                    return
                }
                activeLassoPoints.append(sample.point)
            case nil:
                return
            }
            rebuildRenderedInk()
        }

        private func finishLasso() {
            if let pageIndex = movingSelectionPageIndex {
                finishMovingSelection(pageIndex: pageIndex)
                return
            }
            guard let pageIndex = activeLassoPageIndex,
                  let mode = activeLassoMode else {
                cancelLasso()
                return
            }
            let selected = selectStrokes(pageIndex: pageIndex, mode: mode, points: activeLassoPoints)
            let wasEmptyAreaTap = selected.isEmpty && isEmptyAreaTap()
            let tapLocation = activeLassoPoints.first?.location
            if selected.isEmpty {
                selectedStrokeIDsByPage.removeValue(forKey: pageIndex)
            } else {
                selectedStrokeIDsByPage[pageIndex] = selected
            }
            clearActiveLassoState()
            parent.palette.isStrokeInProgress = false
            rebuildRenderedInk()
            if wasEmptyAreaTap, let pageLocation = tapLocation, InkLassoClipboard.hasStrokes {
                DispatchQueue.main.async { [weak self] in
                    self?.presentPasteShortcut(pageIndex: pageIndex, at: pageLocation)
                }
            }
        }

        private func isEmptyAreaTap() -> Bool {
            guard let startTime = activeStrokeStartTime else { return false }
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            guard elapsed <= Self.tapDurationThreshold else { return false }
            let pts = activeLassoPoints
            guard let first = pts.first?.location else { return false }
            return pts.allSatisfy {
                hypot($0.location.x - first.x, $0.location.y - first.y) <= Self.tapMovementThreshold
            }
        }

        private func presentPasteShortcut(pageIndex: Int, at pageLocation: CGPoint) {
            guard let wrapper else { return }
            let smallRect = CGRect(x: pageLocation.x - 1, y: pageLocation.y - 1, width: 2, height: 2)
            guard let viewRect = convertPageRectToWrapper(pageBounds: smallRect, pageIndex: pageIndex) else { return }
            let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
            LassoSelectionMenu.shared.presentPasteShortcut(in: wrapper, sourcePoint: center) { [weak self] in
                self?.pasteSelectionStrokes(pageIndex: pageIndex, at: pageLocation)
            }
        }

        private func cancelLasso() {
            if let pageIndex = movingSelectionPageIndex,
               let original = movingSelectionOriginalStrokes {
                setStrokes(original, for: pageIndex)
            }
            clearActiveLassoState()
            parent.palette.isStrokeInProgress = false
            rebuildRenderedInk()
        }

        private func clearActiveLassoState() {
            activeLassoPageIndex = nil
            activeLassoMode = nil
            activeLassoPoints = []
            movingSelectionPageIndex = nil
            movingSelectionOriginalStrokes = nil
            movingSelectionLastPoint = nil
            movingSelectionStartPoint = nil
            movingSelectionStartTime = nil
            movingSelectionDidExceedTapThreshold = false
        }

        private func makeInkPoint(from touch: UITouch,
                                  startTime: TimeInterval) -> (pageIndex: Int, point: InkPoint)? {
            guard let pdfView = hostPDFView,
                  let document = pdfView.document else { return nil }
            let location = touch.preciseLocation(in: pdfView)
            guard let page = pdfView.page(for: location, nearest: false) else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return nil }

            let pageBounds = page.bounds(for: .mediaBox)
            let pdfPoint = pdfView.convert(location, to: page)
            guard pageBounds.contains(pdfPoint) else { return nil }

            let pagePoint = CGPoint(
                x: pdfPoint.x - pageBounds.minX,
                y: pageBounds.maxY - pdfPoint.y
            )
            let normalizedForce: CGFloat
            if touch.maximumPossibleForce > 0 {
                normalizedForce = max(0.05, min(touch.force / touch.maximumPossibleForce, 1))
            } else {
                normalizedForce = 1
            }
            let point = InkPoint(
                location: pagePoint,
                force: normalizedForce,
                altitude: touch.altitudeAngle,
                azimuth: touch.azimuthAngle(in: pdfView),
                size: parent.palette.width,
                opacity: currentOpacity,
                timeOffset: touch.timestamp - startTime
            )
            return (pageIndex, point)
        }

        private var currentInkTool: InkTool {
            switch parent.palette.tool {
            case .pen:
                return parent.palette.penKind.inkTool
            case .pencil:
                return .pencil
            case .marker:
                return .marker
            case .eraser:
                return .eraser
            case .lasso:
                return .pen
            }
        }

        private var currentInkColor: InkColor {
            let uiColor = UIColor(parent.palette.color)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 1
            uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return InkColor(
                red: Float(red),
                green: Float(green),
                blue: Float(blue),
                alpha: Float(alpha * currentOpacity)
            )
        }

        private var currentOpacity: CGFloat {
            switch parent.palette.tool {
            case .marker:
                return 0.45
            case .pen, .pencil, .eraser, .lasso:
                return 1
            }
        }

        // MARK: - Stroke mutations / undo

        private func appendCommittedStroke(_ stroke: InkStroke, pageIndex: Int) {
            let before = parent.pageInkStrokes[pageIndex] ?? []
            let after = before + [stroke]
            applyReplacement(pageIndex: pageIndex, before: before, after: after, recordsUndo: true)
        }

        private func erase(with eraserStroke: InkStroke, pageIndex: Int) {
            let before = parent.pageInkStrokes[pageIndex] ?? []
            guard !before.isEmpty else { return }
            let radius = max(eraserStroke.baseWidth * 0.5, 3)
            let after: [InkStroke]
            switch parent.palette.eraserMode {
            case .element:
                after = before.filter { !stroke($0, intersectsEraser: eraserStroke, radius: radius) }
            case .pixel:
                after = before.flatMap { strokeByErasingPixels(in: $0, with: eraserStroke, radius: radius) }
            }
            guard after != before else { return }
            applyReplacement(pageIndex: pageIndex, before: before, after: after, recordsUndo: true)
        }

        private func applyLivePixelErase(with eraserStroke: InkStroke, pageIndex: Int) {
            guard let before = activeEraserOriginalStrokes else { return }
            guard !before.isEmpty else {
                setStrokes([], for: pageIndex)
                rebuildRenderedInk()
                return
            }
            let radius = max(eraserStroke.baseWidth * 0.5, 3)
            let after = before.flatMap { strokeByErasingPixels(in: $0, with: eraserStroke, radius: radius) }
            setStrokes(after, for: pageIndex)
            activatePDFInk(pageIndex: pageIndex)
            rebuildRenderedInk()
        }

        private func finishLivePixelErase(pageIndex: Int) {
            let before = activeEraserOriginalStrokes ?? []
            let after = parent.pageInkStrokes[pageIndex] ?? []
            guard before != after else {
                updateUndoRedoState()
                return
            }
            undoStack.append(PDFInkUndoAction(pageIndex: pageIndex, before: before, after: after))
            redoStack.removeAll()
            activatePDFInk(pageIndex: pageIndex)
            updateUndoRedoState()
        }

        private func applyReplacement(pageIndex: Int,
                                      before: [InkStroke],
                                      after: [InkStroke],
                                      recordsUndo: Bool) {
            setStrokes(after, for: pageIndex)
            if recordsUndo {
                undoStack.append(PDFInkUndoAction(pageIndex: pageIndex, before: before, after: after))
                redoStack.removeAll()
            }
            lastActivePageIndex = pageIndex
            parent.palette.lastActiveCanvas = .pdfInk
            parent.onPDFInkActivated?()
            updateUndoRedoState()
            rebuildRenderedInk()
        }

        private func setStrokes(_ strokes: [InkStroke], for pageIndex: Int) {
            if strokes.isEmpty {
                parent.pageInkStrokes.removeValue(forKey: pageIndex)
            } else {
                parent.pageInkStrokes[pageIndex] = strokes
            }
            pruneSelection(pageIndex: pageIndex, strokes: strokes)
            lastStrokeSignature = strokeSignature(for: parent.pageInkStrokes)
        }

        // MARK: - Lasso selection / movement

        private func shouldMoveSelection(from point: CGPoint, pageIndex: Int) -> Bool {
            guard let selectionBounds = selectedStrokeBounds(pageIndex: pageIndex) else { return false }
            return selectionBounds.insetBy(dx: -18, dy: -18).contains(point)
        }

        private func moveSelectedStrokes(to point: CGPoint, pageIndex: Int) {
            guard let lastPoint = movingSelectionLastPoint,
                  let selectedIDs = selectedStrokeIDsByPage[pageIndex],
                  !selectedIDs.isEmpty else { return }
            if let startPoint = movingSelectionStartPoint,
               !movingSelectionDidExceedTapThreshold,
               hypot(point.x - startPoint.x, point.y - startPoint.y) > Self.tapMovementThreshold {
                movingSelectionDidExceedTapThreshold = true
            }
            let delta = CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
            guard abs(delta.dx) > 0.01 || abs(delta.dy) > 0.01 else { return }
            let current = parent.pageInkStrokes[pageIndex] ?? []
            let moved = current.map { stroke in
                selectedIDs.contains(stroke.id) ? stroke.translated(by: delta) : stroke
            }
            setStrokes(moved, for: pageIndex)
            movingSelectionLastPoint = point
            activatePDFInk(pageIndex: pageIndex)
            rebuildRenderedInk()
        }

        private static let tapMovementThreshold: CGFloat = 6
        private static let tapDurationThreshold: TimeInterval = 0.35

        private func finishMovingSelection(pageIndex: Int) {
            let before = movingSelectionOriginalStrokes ?? []
            let after = parent.pageInkStrokes[pageIndex] ?? []
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = (movingSelectionStartTime.map { now - $0 }) ?? .infinity
            let isTap = !movingSelectionDidExceedTapThreshold
                && elapsed <= Self.tapDurationThreshold
            if isTap {
                if before != after {
                    setStrokes(before, for: pageIndex)
                }
                clearActiveLassoState()
                parent.palette.isStrokeInProgress = false
                rebuildRenderedInk()
                DispatchQueue.main.async { [weak self] in
                    self?.presentSelectionMenu(pageIndex: pageIndex)
                }
                return
            }
            if before != after {
                undoStack.append(PDFInkUndoAction(pageIndex: pageIndex, before: before, after: after))
                redoStack.removeAll()
            }
            clearActiveLassoState()
            activatePDFInk(pageIndex: pageIndex)
            parent.palette.isStrokeInProgress = false
            updateUndoRedoState()
            rebuildRenderedInk()
        }

        private func selectStrokes(pageIndex: Int, mode: LassoMode, points: [InkPoint]) -> Set<UUID> {
            let strokes = parent.pageInkStrokes[pageIndex] ?? []
            guard !strokes.isEmpty else { return [] }
            switch mode {
            case .rectangle:
                guard let rect = lassoRect(from: points) else { return [] }
                return Set(strokes.compactMap { stroke in
                    strokeIntersects(stroke, rect: rect) ? stroke.id : nil
                })
            case .freeform:
                let polygon = points.map(\.location)
                guard polygon.count >= 3 else { return [] }
                let bounds = bounds(for: polygon)
                return Set(strokes.compactMap { stroke in
                    guard stroke.boundingBox.intersects(bounds) else { return nil }
                    return strokeIntersects(stroke, polygon: polygon, bounds: bounds) ? stroke.id : nil
                })
            }
        }

        private func lassoRect(from points: [InkPoint]) -> CGRect? {
            guard let first = points.first?.location,
                  let last = points.last?.location else { return nil }
            return CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(first.x - last.x),
                height: abs(first.y - last.y)
            )
        }

        private func strokeIntersects(_ stroke: InkStroke, rect: CGRect) -> Bool {
            let expanded = rect.insetBy(dx: -stroke.baseWidth * 0.5, dy: -stroke.baseWidth * 0.5)
            guard stroke.boundingBox.intersects(expanded) else { return false }
            return stroke.points.contains { expanded.contains($0.location) }
        }

        private func strokeIntersects(_ stroke: InkStroke,
                                      polygon: [CGPoint],
                                      bounds: CGRect) -> Bool {
            if polygonContains(stroke.boundingBox.center, polygon: polygon) { return true }
            for point in stroke.points {
                if bounds.contains(point.location),
                   polygonContains(point.location, polygon: polygon) {
                    return true
                }
            }
            return false
        }

        private func selectedStrokeBounds(pageIndex: Int) -> CGRect? {
            guard let selectedIDs = selectedStrokeIDsByPage[pageIndex],
                  !selectedIDs.isEmpty else { return nil }
            var union: CGRect?
            for stroke in parent.pageInkStrokes[pageIndex] ?? [] where selectedIDs.contains(stroke.id) {
                union = union.map { $0.union(stroke.boundingBox) } ?? stroke.boundingBox
            }
            return union
        }

        private func pruneSelection(pageIndex: Int, strokes: [InkStroke]) {
            guard let selectedIDs = selectedStrokeIDsByPage[pageIndex] else { return }
            let liveIDs = Set(strokes.map(\.id))
            let pruned = selectedIDs.intersection(liveIDs)
            if pruned.isEmpty {
                selectedStrokeIDsByPage.removeValue(forKey: pageIndex)
            } else {
                selectedStrokeIDsByPage[pageIndex] = pruned
            }
        }

        // MARK: - Selection context menu

        private var activeColorPickerBridge: ColorPickerBridge?

        private func presentSelectionMenu(pageIndex: Int) {
            guard let wrapper,
                  let selectionBounds = selectedStrokeBounds(pageIndex: pageIndex),
                  let sourceRect = convertPageRectToWrapper(pageBounds: selectionBounds,
                                                             pageIndex: pageIndex) else { return }
            lastSelectionMenuPageIndex = pageIndex
            let actions = LassoMenuActions(
                canPaste: InkLassoClipboard.hasStrokes,
                onCut: { [weak self] in self?.cutSelection(pageIndex: pageIndex) },
                onCopy: { [weak self] in self?.copySelection(pageIndex: pageIndex) },
                onPaste: { [weak self] in self?.pasteSelectionStrokes(pageIndex: pageIndex) },
                onRecolor: { [weak self] color in self?.recolorSelection(pageIndex: pageIndex, color: color) },
                onPickCustomColor: { [weak self] in self?.presentCustomColorPicker(pageIndex: pageIndex) },
                onDelete: { [weak self] in self?.deleteSelection(pageIndex: pageIndex) }
            )
            LassoSelectionMenu.shared.present(in: wrapper, sourceRect: sourceRect, actions: actions)
        }

        private func convertPageRectToWrapper(pageBounds: CGRect, pageIndex: Int) -> CGRect? {
            guard let pdfView = hostPDFView,
                  let document = pdfView.document,
                  let page = document.page(at: pageIndex),
                  let wrapper else { return nil }
            let mediaBox = page.bounds(for: .mediaBox)
            let p1 = pdfView.convert(
                CGPoint(x: mediaBox.minX + pageBounds.minX,
                        y: mediaBox.maxY - pageBounds.minY),
                from: page
            )
            let p2 = pdfView.convert(
                CGPoint(x: mediaBox.minX + pageBounds.maxX,
                        y: mediaBox.maxY - pageBounds.maxY),
                from: page
            )
            let pdfViewRect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
            return pdfView.convert(pdfViewRect, to: wrapper)
        }

        private func cutSelection(pageIndex: Int) {
            copySelection(pageIndex: pageIndex)
            deleteSelection(pageIndex: pageIndex)
        }

        private func copySelection(pageIndex: Int) {
            guard let selectedIDs = selectedStrokeIDsByPage[pageIndex] else { return }
            let strokes = (parent.pageInkStrokes[pageIndex] ?? [])
                .filter { selectedIDs.contains($0.id) }
            InkLassoClipboard.copy(strokes)
        }

        func pasteSelectionStrokes(pageIndex: Int, at pageLocation: CGPoint? = nil) {
            guard let strokes = InkLassoClipboard.paste(), !strokes.isEmpty else { return }
            let before = parent.pageInkStrokes[pageIndex] ?? []
            let union = strokes.dropFirst().reduce(strokes[0].boundingBox) { $0.union($1.boundingBox) }
            let center = CGPoint(x: union.midX, y: union.midY)
            let target: CGPoint
            if let pageLocation {
                target = pageLocation
            } else if let existing = selectedStrokeBounds(pageIndex: pageIndex) {
                target = CGPoint(x: existing.midX + 20, y: existing.midY + 20)
            } else {
                target = CGPoint(x: center.x + 20, y: center.y + 20)
            }
            let delta = CGVector(dx: target.x - center.x, dy: target.y - center.y)
            let translated = strokes.map { $0.translated(by: delta) }
            let after = before + translated
            selectedStrokeIDsByPage[pageIndex] = Set(translated.map(\.id))
            applyReplacement(pageIndex: pageIndex, before: before, after: after, recordsUndo: true)
        }

        private func deleteSelection(pageIndex: Int) {
            guard let selectedIDs = selectedStrokeIDsByPage[pageIndex],
                  !selectedIDs.isEmpty else { return }
            let before = parent.pageInkStrokes[pageIndex] ?? []
            let after = before.filter { !selectedIDs.contains($0.id) }
            guard after.count != before.count else { return }
            selectedStrokeIDsByPage.removeValue(forKey: pageIndex)
            applyReplacement(pageIndex: pageIndex, before: before, after: after, recordsUndo: true)
        }

        private func recolorSelection(pageIndex: Int, color: Color) {
            guard let selectedIDs = selectedStrokeIDsByPage[pageIndex],
                  !selectedIDs.isEmpty else { return }
            let before = parent.pageInkStrokes[pageIndex] ?? []
            var didChange = false
            let after = before.map { stroke -> InkStroke in
                guard selectedIDs.contains(stroke.id) else { return stroke }
                let originalAlpha = CGFloat(stroke.color.alpha)
                let newColor = InkColor(color, alpha: originalAlpha)
                if newColor == stroke.color { return stroke }
                didChange = true
                var copy = stroke
                copy.color = newColor
                return copy
            }
            guard didChange else { return }
            applyReplacement(pageIndex: pageIndex, before: before, after: after, recordsUndo: true)
        }

        private func presentCustomColorPicker(pageIndex: Int) {
            guard let wrapper,
                  let presenter = wrapper.findTopPresenter() else { return }
            let picker = UIColorPickerViewController()
            picker.supportsAlpha = false
            picker.selectedColor = UIColor(parent.palette.color)
            let bridge = ColorPickerBridge { [weak self] color in
                guard let self else { return }
                self.activeColorPickerBridge = nil
                if let color {
                    self.recolorSelection(pageIndex: pageIndex, color: Color(color))
                }
            }
            picker.delegate = bridge
            activeColorPickerBridge = bridge
            presenter.present(picker, animated: true)
        }

        private func bounds(for points: [CGPoint]) -> CGRect {
            guard let first = points.first else { return .zero }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        private func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
            guard polygon.count >= 3 else { return false }
            var isInside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let pi = polygon[i]
                let pj = polygon[j]
                if (pi.y > point.y) != (pj.y > point.y) {
                    let dy = pj.y - pi.y
                    let denominator = abs(dy) < .leastNonzeroMagnitude ? .leastNonzeroMagnitude : dy
                    let x = (pj.x - pi.x) * (point.y - pi.y) / denominator + pi.x
                    if point.x < x {
                        isInside.toggle()
                    }
                }
                j = i
            }
            return isInside
        }

        private func stroke(_ stroke: InkStroke,
                            intersectsEraser eraser: InkStroke,
                            radius: CGFloat) -> Bool {
            let expanded = stroke.boundingBox.insetBy(dx: -radius, dy: -radius)
            guard expanded.intersects(eraser.boundingBox) else { return false }
            let threshold = radius + stroke.baseWidth * 0.5
            let thresholdSquared = threshold * threshold
            for eraserPoint in eraser.points {
                for strokePoint in stroke.points {
                    let dx = eraserPoint.location.x - strokePoint.location.x
                    let dy = eraserPoint.location.y - strokePoint.location.y
                    if dx * dx + dy * dy <= thresholdSquared {
                        return true
                    }
                }
            }
            return false
        }

        private func strokeByErasingPixels(in stroke: InkStroke,
                                           with eraser: InkStroke,
                                           radius: CGFloat) -> [InkStroke] {
            let expanded = stroke.boundingBox.insetBy(dx: -radius, dy: -radius)
            guard expanded.intersects(eraser.boundingBox) else { return [stroke] }

            var fragments: [[InkPoint]] = []
            var current: [InkPoint] = []
            var didErasePoint = false
            for point in stroke.points {
                if isPoint(point, insideEraser: eraser, strokeWidth: stroke.baseWidth, radius: radius) {
                    didErasePoint = true
                    if !current.isEmpty {
                        fragments.append(current)
                        current.removeAll(keepingCapacity: true)
                    }
                } else {
                    current.append(point)
                }
            }
            if !current.isEmpty {
                fragments.append(current)
            }

            guard didErasePoint else { return [stroke] }
            return fragments.compactMap { points in
                guard !points.isEmpty else { return nil }
                return InkStroke(
                    tool: stroke.tool,
                    color: stroke.color,
                    baseWidth: stroke.baseWidth,
                    points: points
                )
            }
        }

        private func isPoint(_ point: InkPoint,
                             insideEraser eraser: InkStroke,
                             strokeWidth: CGFloat,
                             radius: CGFloat) -> Bool {
            let threshold = radius + strokeWidth * 0.5
            let thresholdSquared = threshold * threshold
            for eraserPoint in eraser.points {
                let dx = eraserPoint.location.x - point.location.x
                let dy = eraserPoint.location.y - point.location.y
                if dx * dx + dy * dy <= thresholdSquared {
                    return true
                }
            }
            return false
        }

        func handleUndoRedoIfNeeded() {
            guard parent.palette.lastActiveCanvas == .pdfInk else { return }
            if let trigger = parent.palette.undoTrigger, lastUndoTrigger != trigger {
                lastUndoTrigger = trigger
                performUndo()
            }
            if let trigger = parent.palette.redoTrigger, lastRedoTrigger != trigger {
                lastRedoTrigger = trigger
                performRedo()
            }
        }

        private func performUndo() {
            guard let action = undoStack.popLast() else { return }
            setStrokes(action.before, for: action.pageIndex)
            redoStack.append(action)
            lastActivePageIndex = action.pageIndex
            updateUndoRedoState()
            rebuildRenderedInk()
        }

        private func performRedo() {
            guard let action = redoStack.popLast() else { return }
            setStrokes(action.after, for: action.pageIndex)
            undoStack.append(action)
            lastActivePageIndex = action.pageIndex
            updateUndoRedoState()
            rebuildRenderedInk()
        }

        private func updateUndoRedoState() {
            publishPDFUndoRedoState(canUndo: !undoStack.isEmpty,
                                    canRedo: !redoStack.isEmpty)
        }

        private func publishPDFUndoRedoState(canUndo: Bool, canRedo: Bool) {
            guard parent.palette.pdfCanUndo != canUndo || parent.palette.pdfCanRedo != canRedo else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.palette.pdfCanUndo = canUndo
                self.parent.palette.pdfCanRedo = canRedo
            }
        }

        private func strokeSignature(for strokesByPage: [Int: [InkStroke]]) -> String {
            strokesByPage.keys.sorted().map { pageIndex in
                let ids = strokesByPage[pageIndex, default: []].map(\.id.uuidString).joined(separator: ",")
                return "\(pageIndex):\(ids)"
            }.joined(separator: "|")
        }

        // MARK: - Page-attached ink rendering

        func rebuildRenderedInk() {
            guard let hostPDFView,
                  let document = hostPDFView.document else { return }
            let visiblePages = hostPDFView.visiblePages
            let pages = visiblePages.isEmpty ? hostPDFView.currentPage.map { [$0] } ?? [] : visiblePages

            for page in pages {
                updateInkOverlay(for: page, in: hostPDFView, document: document)
            }
        }

        private func eraserPreviewStrokeIDs(pageIndex: Int, strokes: [InkStroke]) -> Set<UUID> {
            guard pageIndex == activePageIndex,
                  let activeStroke,
                  activeStroke.tool == .eraser,
                  parent.palette.eraserMode == .element,
                  !activeStroke.points.isEmpty else {
                return []
            }
            let radius = max(activeStroke.baseWidth * 0.5, 3)
            return Set(strokes.compactMap { stroke in
                self.stroke(stroke, intersectsEraser: activeStroke, radius: radius) ? stroke.id : nil
            })
        }

        private func updateInkOverlay(for page: PDFPage, in pdfView: PDFView, document: PDFDocument) {
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0,
                  let renderView = pageRenderViews[pageIndex] else { return }
            let strokes = parent.pageInkStrokes[pageIndex] ?? []
            let activeStrokeForPage: InkStroke?
            if pageIndex == activePageIndex, activeStroke?.tool != .eraser {
                activeStrokeForPage = activeStroke
            } else {
                activeStrokeForPage = nil
            }
            renderView.update(
                strokes: strokes,
                activeStroke: activeStrokeForPage,
                eraserPreviewIDs: eraserPreviewStrokeIDs(pageIndex: pageIndex, strokes: strokes),
                selectedStrokeIDs: selectedStrokeIDsByPage[pageIndex] ?? [],
                activeLassoPoints: pageIndex == activeLassoPageIndex ? activeLassoPoints : [],
                activeLassoMode: pageIndex == activeLassoPageIndex ? activeLassoMode : nil
            )
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let document = view.document else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return nil }

            let renderView = PDFInkPageRenderView(page: page, displayBox: view.displayBox)
            pageRenderViews[pageIndex] = renderView
            updateInkOverlay(for: page, in: view, document: document)
            return renderView
        }

        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            guard let document = pdfView.document else { return }
            updateInkOverlay(for: page, in: pdfView, document: document)
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let document = pdfView.document else { return }
            let pageIndex = document.index(for: page)
            if pageIndex >= 0,
               let currentRenderView = pageRenderViews[pageIndex],
               currentRenderView === overlayView {
                pageRenderViews.removeValue(forKey: pageIndex)
            }
        }

        // MARK: - Touch activation

        private func activateVisiblePDFSurface() {
            let pageIndex = currentVisiblePageIndex()
            lastActivePageIndex = pageIndex ?? lastActivePageIndex
            parent.palette.lastActiveCanvas = .pdfInk
            parent.onPDFInkActivated?()
        }

        private func currentVisiblePageIndex() -> Int? {
            guard let hostPDFView,
                  let document = hostPDFView.document else { return nil }
            if let currentPage = hostPDFView.currentPage {
                let index = document.index(for: currentPage)
                if index >= 0 { return index }
            }
            for page in hostPDFView.visiblePages {
                let index = document.index(for: page)
                if index >= 0 { return index }
            }
            return nil
        }

        // MARK: - Pencil interaction

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            Task { @MainActor [weak self] in
                self?.parent.onPencilTap?()
            }
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
            Task { @MainActor [weak self] in
                self?.parent.onPencilTap?()
            }
        }

        // MARK: - Viewport tracking

        private func startDisplayLink() {
            stopDisplayLink()
            let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func displayLinkTick() {
            defer { displayLink?.isPaused = true }
            guard let hostPDFView else { return }
            let key = viewportKey(pdfView: hostPDFView)
            if key != lastViewportKey {
                lastViewportKey = key
                rebuildRenderedInk()
                refreshHoverIndicator()
                if let overlay = anchorOverlay {
                    overlay.frame = hostPDFView.bounds
                    overlay.relayoutForViewportChange()
                    hostPDFView.bringSubviewToFront(overlay)
                }
                if let live = liveHighlightOverlay {
                    live.frame = hostPDFView.bounds
                    live.setNeedsDisplay()
                    hostPDFView.bringSubviewToFront(live)
                }
            }
        }

        private func viewportKey(pdfView: PDFView) -> String {
            let visible = pdfView.visiblePages.compactMap { page -> String? in
                guard let document = pdfView.document else { return nil }
                let idx = document.index(for: page)
                guard idx >= 0 else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                let topLeft = pdfView.convert(CGPoint(x: bounds.minX, y: bounds.maxY), from: page)
                return "\(idx):\(Int(topLeft.x * 10)):\(Int(topLeft.y * 10))"
            }.joined(separator: "|")
            return [
                "\(pdfView.scaleFactor)",
                "\(Int(pdfView.bounds.width))x\(Int(pdfView.bounds.height))",
                visible
            ].joined(separator: "#")
        }

        private func attachScrollObservers() {
            guard let hostPDFView, internalScrollView == nil,
                  let scrollView = findInternalScrollView(in: hostPDFView) else { return }
            internalScrollView = scrollView
            scrollObservations.append(scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.invalidateViewportTracking()
                }
            })
            scrollObservations.append(scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.invalidateViewportTracking()
                }
            })
        }

        private func invalidateViewportTracking() {
            lastViewportKey = ""
            activateVisiblePDFSurface()
            displayLink?.isPaused = false
        }

        private func detachScrollObservers() {
            scrollObservations.forEach { $0.invalidate() }
            scrollObservations.removeAll()
            internalScrollView = nil
        }

        private func findInternalScrollView(in root: UIView) -> UIScrollView? {
            for subview in root.subviews {
                if let scrollView = subview as? UIScrollView { return scrollView }
                if let nested = findInternalScrollView(in: subview) { return nested }
            }
            return nil
        }

        // MARK: - Hover indicator

        @available(iOS 16.1, *)
        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard activeStroke == nil,
                  activeLassoPageIndex == nil,
                  movingSelectionPageIndex == nil else {
                hoverIndicatorView?.hide()
                return
            }
            guard recognizer.state == .began || recognizer.state == .changed else {
                hoverIndicatorView?.hide()
                return
            }
            guard let hostPDFView else { return }
            let location = recognizer.location(in: hostPDFView)
            updateHoverIndicator(at: location)
        }

        private func refreshHoverIndicator() {
            guard activeStroke == nil,
                  activeLassoPageIndex == nil,
                  movingSelectionPageIndex == nil else {
                hoverIndicatorView?.hide()
                return
            }
            guard let hostPDFView, let hoverIndicatorView, !hoverIndicatorView.isHidden else { return }
            updateHoverIndicator(at: hoverIndicatorView.center, in: hostPDFView)
        }

        private func updateHoverIndicator(at location: CGPoint) {
            guard let hostPDFView else { return }
            updateHoverIndicator(at: location, in: hostPDFView)
        }

        private func updateHoverIndicator(at location: CGPoint, in pdfView: PDFView) {
            guard let page = pdfView.page(for: location, nearest: false) else {
                hoverIndicatorView?.hide()
                return
            }
            let pointOnPage = pdfView.convert(location, to: page)
            guard page.bounds(for: .mediaBox).contains(pointOnPage) else {
                hoverIndicatorView?.hide()
                return
            }
            hoverIndicatorView?.show(
                at: location,
                diameter: hoverDiameter(),
                color: hoverColor()
            )
        }

        private func hoverDiameter() -> CGFloat {
            switch parent.palette.tool {
            case .pen, .pencil, .marker, .eraser:
                return max(8, min(parent.palette.width, 44))
            case .lasso:
                return 18
            }
        }

        private func hoverColor() -> UIColor {
            switch parent.palette.tool {
            case .eraser, .lasso:
                return .label
            case .pen, .pencil, .marker:
                return UIColor(parent.palette.color)
            }
        }

        // MARK: - Navigation

        func scroll(to target: PDFNavigationTarget, in pdfView: PDFView) {
            guard let document = pdfView.document,
                  let page = document.page(at: target.pageIndex) else { return }
            let dest: PDFDestination
            if target.pageRect.isEmpty {
                let pageBounds = page.bounds(for: .mediaBox)
                dest = PDFDestination(page: page, at: CGPoint(x: 0, y: pageBounds.height))
            } else {
                dest = PDFDestination(page: page,
                                      at: CGPoint(x: target.pageRect.minX,
                                                  y: target.pageRect.maxY + 20))
            }
            pdfView.go(to: dest)
            invalidateViewportTracking()
            if !target.pageRect.isEmpty {
                addTemporaryHighlight(rect: target.pageRect, on: page)
            }
        }

        private func addTemporaryHighlight(rect: CGRect, on page: PDFPage) {
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = UIColor.systemYellow.withAlphaComponent(0.5)
            page.addAnnotation(annotation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak page] in
                page?.removeAnnotation(annotation)
            }
        }

        // MARK: - Drag (selection-based fallback)
        //
        // Anchor-based drag is handled by PDFAnchorOverlay. The selection drag
        // interaction remains so an ad-hoc text selection (e.g. while a
        // non-marker tool is active) can still be dragged into the canvas
        // without being promoted to a permanent highlight.

        func dragInteraction(_ interaction: UIDragInteraction,
                             itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            guard let pdfView = interaction.view as? PDFView,
                  let selection = pdfView.currentSelection,
                  let text = selection.string,
                  !text.isEmpty,
                  let page = selection.pages.first else {
                return []
            }
            // If marker is active and we just finalized a highlight, the
            // selection might briefly persist; suppress the legacy drag so the
            // anchor flow owns the new highlight.
            if parent.palette.tool == .marker { return [] }
            let pageIndex = pdfView.document?.index(for: page) ?? 0
            let pageBounds = selection.bounds(for: page)
            let payload = TextScrapPayload(text: text,
                                           pageIndex: pageIndex,
                                           pageBounds: pageBounds)
            let provider = NSItemProvider(object: text as NSString)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = payload
            return [item]
        }
    }
}

private struct PDFInkUndoAction {
    var pageIndex: Int
    var before: [InkStroke]
    var after: [InkStroke]
}

private struct PDFInkOutlineCacheKey: Hashable {
    var strokeID: UUID
    var pointCount: Int
    var toolRawValue: Int
    var baseWidth: Double
    var red: UInt32
    var green: UInt32
    var blue: UInt32
    var alpha: UInt32
    var lastX: Double
    var lastY: Double
    var lastForce: Double

    init(stroke: InkStroke) {
        let last = stroke.points.last
        strokeID = stroke.id
        pointCount = stroke.points.count
        toolRawValue = stroke.tool.rawValue
        baseWidth = Double(stroke.baseWidth)
        red = stroke.color.red.bitPattern
        green = stroke.color.green.bitPattern
        blue = stroke.color.blue.bitPattern
        alpha = stroke.color.alpha.bitPattern
        lastX = Double(last?.location.x ?? 0)
        lastY = Double(last?.location.y ?? 0)
        lastForce = Double(last?.force ?? 0)
    }
}

private final class PDFInkPageRenderView: UIView {
    private weak var page: PDFPage?
    private let displayBox: PDFDisplayBox
    private var strokes: [InkStroke] = []
    private var activeStroke: InkStroke?
    private var eraserPreviewIDs: Set<UUID> = []
    private var selectedStrokeIDs: Set<UUID> = []
    private var activeLassoPoints: [InkPoint] = []
    private var activeLassoMode: LassoMode?
    private var outlineCache: [PDFInkOutlineCacheKey: CGPath] = [:]
    private var lastBoundsSize: CGSize = .zero

    init(page: PDFPage, displayBox: PDFDisplayBox) {
        self.page = page
        self.displayBox = displayBox
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        for stroke in strokes {
            draw(stroke, isComplete: true, opacity: eraserPreviewIDs.contains(stroke.id) ? 0.28 : 1, in: context)
        }
        if let activeStroke {
            draw(activeStroke, isComplete: false, opacity: 1, in: context)
        }
        drawSelectionOverlay(in: context)
        drawActiveLasso(in: context)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            setNeedsDisplay()
        }
    }

    func update(strokes: [InkStroke],
                activeStroke: InkStroke?,
                eraserPreviewIDs: Set<UUID>,
                selectedStrokeIDs: Set<UUID>,
                activeLassoPoints: [InkPoint],
                activeLassoMode: LassoMode?) {
        self.strokes = strokes
        self.activeStroke = activeStroke
        self.eraserPreviewIDs = eraserPreviewIDs
        self.selectedStrokeIDs = selectedStrokeIDs
        self.activeLassoPoints = activeLassoPoints
        self.activeLassoMode = activeLassoMode
        setNeedsDisplay()
    }

    func clear() {
        strokes = []
        activeStroke = nil
        eraserPreviewIDs = []
        selectedStrokeIDs = []
        activeLassoPoints = []
        activeLassoMode = nil
        outlineCache.removeAll()
        setNeedsDisplay()
    }

    private func draw(_ stroke: InkStroke,
                      isComplete: Bool,
                      opacity: CGFloat,
                      in context: CGContext) {
        guard stroke.tool != .eraser,
              let pagePath = pageSpaceOutlinePath(for: stroke, isComplete: isComplete),
              var transform = pageSpaceToLocalTransform(),
              let localPath = pagePath.copy(using: &transform) else { return }

        let isMarker = stroke.tool == .marker || stroke.tool == .highlighter
        context.saveGState()
        context.setBlendMode(isMarker ? .multiply : .normal)
        context.setAlpha(opacity)
        context.setFillColor(stroke.color.uiColor.cgColor)
        context.addPath(localPath)
        context.fillPath()
        context.restoreGState()
    }

    private func drawSelectionOverlay(in context: CGContext) {
        guard !selectedStrokeIDs.isEmpty,
              var selectionBounds = selectedStrokeBounds(),
              let transform = pageSpaceToLocalTransform() else { return }
        selectionBounds = selectionBounds.insetBy(dx: -6, dy: -6)
        let rect = selectionBounds.applying(transform).standardized
        context.saveGState()
        context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [7, 4])
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private func drawActiveLasso(in context: CGContext) {
        guard let activeLassoMode,
              !activeLassoPoints.isEmpty,
              let transform = pageSpaceToLocalTransform() else { return }
        context.saveGState()
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(1.7)
        context.setLineDash(phase: 0, lengths: [6, 4])
        switch activeLassoMode {
        case .rectangle:
            guard let first = activeLassoPoints.first?.location,
                  let last = activeLassoPoints.last?.location else {
                context.restoreGState()
                return
            }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(first.x - last.x),
                height: abs(first.y - last.y)
            ).applying(transform).standardized
            context.stroke(rect)
        case .freeform:
            let points = activeLassoPoints.map { $0.location.applying(transform) }
            guard let first = points.first else {
                context.restoreGState()
                return
            }
            let path = UIBezierPath()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path.cgPath)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func selectedStrokeBounds() -> CGRect? {
        var union: CGRect?
        for stroke in strokes where selectedStrokeIDs.contains(stroke.id) {
            union = union.map { $0.union(stroke.boundingBox) } ?? stroke.boundingBox
        }
        return union
    }

    private func pageSpaceOutlinePath(for stroke: InkStroke, isComplete: Bool) -> CGPath? {
        if isComplete {
            let key = PDFInkOutlineCacheKey(stroke: stroke)
            if let cached = outlineCache[key] {
                return cached
            }
            guard let outline = InkStrokeGeometry.outline(for: stroke, isComplete: true) else { return nil }
            let path = outline.makeClosedPath()
            outlineCache[key] = path
            return path
        }

        guard let outline = InkStrokeGeometry.outline(for: stroke, isComplete: false) else { return nil }
        return outline.makeClosedPath()
    }

    private func pageSpaceToLocalTransform() -> CGAffineTransform? {
        guard let page else { return nil }
        let mediaBounds = page.bounds(for: .mediaBox)
        let displayBounds = page.bounds(for: displayBox)
        guard mediaBounds.width > 0, mediaBounds.height > 0,
              displayBounds.width > 0, displayBounds.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let scaleX = bounds.width / displayBounds.width
        let scaleY = bounds.height / displayBounds.height
        return CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: (mediaBounds.minX - displayBounds.minX) * scaleX,
            ty: (displayBounds.maxY - mediaBounds.maxY) * scaleY
        )
    }
}

private final class PencilHoverIndicatorView: UIView {
    private let ringLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .clear
        layer.addSublayer(ringLayer)
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 1.5
        ringLayer.shadowColor = UIColor.black.cgColor
        ringLayer.shadowOpacity = 0.12
        ringLayer.shadowRadius = 2
        ringLayer.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func show(at point: CGPoint, diameter: CGFloat, color: UIColor) {
        let size = CGSize(width: diameter, height: diameter)
        bounds = CGRect(origin: .zero, size: size)
        center = point
        isHidden = false

        ringLayer.frame = bounds
        ringLayer.strokeColor = color.withAlphaComponent(0.85).cgColor
        ringLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
    }

    func hide() {
        isHidden = true
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

final class ColorPickerBridge: NSObject, UIColorPickerViewControllerDelegate {
    private let completion: (UIColor?) -> Void
    private var settledColor: UIColor?
    private var didReportFinal = false

    init(completion: @escaping (UIColor?) -> Void) {
        self.completion = completion
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                   didSelect color: UIColor,
                                   continuously: Bool) {
        settledColor = color
        if !continuously {
            reportFinal(color: color)
        }
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        reportFinal(color: settledColor ?? viewController.selectedColor)
    }

    private func reportFinal(color: UIColor) {
        guard !didReportFinal else { return }
        didReportFinal = true
        completion(color)
    }
}

extension UIView {
    /// Walks the responder chain to find the top-most view controller that can
    /// present another view controller. Used to present color pickers.
    func findTopPresenter() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder {
            if let vc = next as? UIViewController {
                var top: UIViewController = vc
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = next.next
        }
        if let scene = window?.windowScene,
           let rootVC = scene.keyWindow?.rootViewController {
            var top = rootVC
            while let presented = top.presentedViewController { top = presented }
            return top
        }
        return nil
    }
}

extension InkStroke {
    func translated(by delta: CGVector) -> InkStroke {
        var copy = self
        copy.points = copy.points.map { point in
            var translatedPoint = point
            translatedPoint.location.x += delta.dx
            translatedPoint.location.y += delta.dy
            return translatedPoint
        }
        copy.boundingBox = Self.computeBoundingBox(for: copy.points, baseWidth: copy.baseWidth)
        return copy
    }
}
