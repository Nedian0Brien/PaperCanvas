import SwiftUI
import PDFKit
import PencilKit
import UIKit

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var navigationTarget: PDFNavigationTarget?
    @Binding var pageInkDrawings: [Int: PKDrawing]
    let palette: PaletteState
    var onRegionCaptured: ((Int, CGRect, UIImage) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        view.isInMarkupMode = true
        view.pageOverlayViewProvider = context.coordinator
        view.document = document
        view.addInteraction(UIDragInteraction(delegate: context.coordinator))
        context.coordinator.attach(to: view)
        let marquee = RegionMarqueeController(pdfView: view)
        marquee.onRegionCaptured = { [weak coord = context.coordinator] pageIdx, rect, img in
            coord?.parent.onRegionCaptured?(pageIdx, rect, img)
        }
        context.coordinator.regionMarquee = marquee
        DispatchQueue.main.async {
            if let page = document.page(at: currentPageIndex) {
                view.go(to: page)
            }
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.parent = self
        if uiView.document !== document {
            context.coordinator.clearCanvases()
            uiView.document = document
            DispatchQueue.main.async {
                if let page = document.page(at: currentPageIndex) {
                    uiView.go(to: page)
                } else {
                    uiView.goToFirstPage(nil)
                }
            }
        }
        if let target = navigationTarget, context.coordinator.lastConsumedTargetID != target.id {
            context.coordinator.lastConsumedTargetID = target.id
            context.coordinator.scroll(to: target, in: uiView)
            DispatchQueue.main.async {
                self.navigationTarget = nil
            }
        }
        context.coordinator.applyToolToVisibleCanvases()
        context.coordinator.applyExternalDrawings()
        context.coordinator.handleUndoRedoIfNeeded()
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        uiView.pageOverlayViewProvider = nil
        coordinator.detach()
    }

    final class Coordinator: NSObject,
                             UIDragInteractionDelegate,
                             PDFPageOverlayViewProvider,
                             PKCanvasViewDelegate {
        var parent: PDFKitView
        var lastConsumedTargetID: UUID?
        var regionMarquee: RegionMarqueeController?
        private weak var pdfView: PDFView?
        private var pageObserver: NSObjectProtocol?
        private var pageToCanvas: [Int: PencilOnlyCanvasView] = [:]
        private var canvasToPage: [ObjectIdentifier: Int] = [:]
        private var lastSyncedDataByPage: [Int: Data] = [:]
        private var isApplyingExternalDrawing = false
        private var lastActivePageIndex: Int?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?

        init(_ parent: PDFKitView) { self.parent = parent }

        func attach(to view: PDFView) {
            pdfView = view
            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                self?.syncPageIndex()
            }
        }

        func detach() {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
            clearCanvases()
        }

        func clearCanvases() {
            pageToCanvas.removeAll()
            canvasToPage.removeAll()
            lastSyncedDataByPage.removeAll()
            lastActivePageIndex = nil
        }

        private func syncPageIndex() {
            guard let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else { return }
            let idx = document.index(for: page)
            if idx >= 0, parent.currentPageIndex != idx {
                parent.currentPageIndex = idx
            }
        }

        // MARK: - PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let document = view.document else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return nil }

            if let existing = pageToCanvas[pageIndex] { return existing }

            let pageBounds = page.bounds(for: .mediaBox)
            let canvas = PencilOnlyCanvasView(frame: pageBounds)
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isUserInteractionEnabled = true
            #if targetEnvironment(simulator)
            canvas.drawingPolicy = .anyInput
            #else
            canvas.drawingPolicy = .pencilOnly
            #endif
            canvas.tool = parent.palette.pkTool
            canvas.delegate = self
            canvas.layer.allowsGroupOpacity = false

            if let stored = parent.pageInkDrawings[pageIndex] {
                canvas.drawing = stored
                lastSyncedDataByPage[pageIndex] = stored.dataRepresentation()
            } else {
                lastSyncedDataByPage[pageIndex] = canvas.drawing.dataRepresentation()
            }

            pageToCanvas[pageIndex] = canvas
            canvasToPage[ObjectIdentifier(canvas)] = pageIndex
            return canvas
        }

        func pdfView(_ pdfView: PDFView,
                     willEndDisplayingOverlayView overlayView: UIView,
                     for page: PDFPage) {
            guard let canvas = overlayView as? PencilOnlyCanvasView,
                  let pageIndex = canvasToPage[ObjectIdentifier(canvas)] else { return }
            commitDrawing(from: canvas, pageIndex: pageIndex)
            pageToCanvas[pageIndex] = nil
            canvasToPage[ObjectIdentifier(canvas)] = nil
            if lastActivePageIndex == pageIndex { lastActivePageIndex = nil }
        }

        // MARK: - Tool sync / external drawing

        func applyToolToVisibleCanvases() {
            for canvas in pageToCanvas.values {
                canvas.tool = parent.palette.pkTool
            }
        }

        func applyExternalDrawings() {
            for (pageIndex, canvas) in pageToCanvas {
                let target = parent.pageInkDrawings[pageIndex] ?? PKDrawing()
                let targetData = target.dataRepresentation()
                if targetData != lastSyncedDataByPage[pageIndex] {
                    isApplyingExternalDrawing = true
                    canvas.drawing = target
                    isApplyingExternalDrawing = false
                    lastSyncedDataByPage[pageIndex] = targetData
                }
            }
        }

        // MARK: - PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing,
                  let pageIndex = canvasToPage[ObjectIdentifier(canvasView)] else { return }
            commitDrawing(from: canvasView, pageIndex: pageIndex)
            lastActivePageIndex = pageIndex
            parent.palette.lastActiveCanvas = .pdfInk
            parent.palette.pdfCanUndo = canvasView.undoManager?.canUndo ?? false
            parent.palette.pdfCanRedo = canvasView.undoManager?.canRedo ?? false
        }

        private func commitDrawing(from canvas: PKCanvasView, pageIndex: Int) {
            let drawing = canvas.drawing
            let data = drawing.dataRepresentation()
            if data != lastSyncedDataByPage[pageIndex] {
                lastSyncedDataByPage[pageIndex] = data
                if drawing.strokes.isEmpty {
                    parent.pageInkDrawings.removeValue(forKey: pageIndex)
                } else {
                    parent.pageInkDrawings[pageIndex] = drawing
                }
            }
        }

        // MARK: - Undo / Redo

        func handleUndoRedoIfNeeded() {
            guard parent.palette.lastActiveCanvas == .pdfInk,
                  let pageIndex = lastActivePageIndex,
                  let canvas = pageToCanvas[pageIndex] else { return }
            var didFire = false
            if let trigger = parent.palette.undoTrigger, lastUndoTrigger != trigger {
                lastUndoTrigger = trigger
                canvas.undoManager?.undo()
                didFire = true
            }
            if let trigger = parent.palette.redoTrigger, lastRedoTrigger != trigger {
                lastRedoTrigger = trigger
                canvas.undoManager?.redo()
                didFire = true
            }
            if didFire {
                DispatchQueue.main.async { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.commitDrawing(from: canvas, pageIndex: pageIndex)
                    self.parent.palette.pdfCanUndo = canvas.undoManager?.canUndo ?? false
                    self.parent.palette.pdfCanRedo = canvas.undoManager?.canRedo ?? false
                }
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

        // MARK: - Drag

        func dragInteraction(_ interaction: UIDragInteraction,
                             itemsForBeginning session: UIDragSession) -> [UIDragItem] {
            guard let pdfView = interaction.view as? PDFView,
                  let selection = pdfView.currentSelection,
                  let text = selection.string,
                  !text.isEmpty,
                  let page = selection.pages.first else {
                return []
            }
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
