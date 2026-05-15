import SwiftUI
import PencilKit
import UIKit

@MainActor
struct InfiniteCanvasContainer: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var contentOffset: CGPoint
    @Binding var resetTrigger: UUID?
    let initialContentSize: CGSize
    let scraps: [ScrapItem]
    let tool: PKTool
    let undoTrigger: UUID?
    let redoTrigger: UUID?
    let isMainCanvasActive: Bool
    var background: CanvasBackground = .dots
    var onScrapTap: ((UUID) -> Void)? = nil
    var onDrop: ((CanvasDropPayload) -> Void)? = nil
    var onScrapMoved: ((UUID, CGPoint) -> Void)? = nil
    var onScrapResized: ((UUID, CGSize) -> Void)? = nil
    var onScrapDeleted: ((UUID) -> Void)? = nil
    var onUndoRedoStateChanged: ((Bool, Bool) -> Void)? = nil
    var onMainCanvasActivated: (() -> Void)? = nil
    var onPencilTap: (() -> Void)? = nil
    var onZoomChanged: ((CGFloat) -> Void)? = nil
    var onStrokeBegan: (() -> Void)? = nil
    var onStrokeEnded: (() -> Void)? = nil

    static let defaultContentSize = CGSize(width: 4000, height: 4000)
    static let expansionMargin: CGFloat = 600
    static let expansionStep: CGFloat = 1500
    static let maxContentDimension: CGFloat = 30000

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .systemBackground
        wrapper.clipsToBounds = true

        let canvas = PKCanvasView()
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        canvas.backgroundColor = background.uiBackgroundColor()
        canvas.isOpaque = true
        canvas.layer.allowsGroupOpacity = false
        canvas.delegate = context.coordinator
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = true
        canvas.minimumZoomScale = 0.5
        canvas.maximumZoomScale = 4.0
        canvas.contentSize = initialContentSize
        canvas.tool = tool
        canvas.drawing = drawing
        canvas.addInteraction(UIDropInteraction(delegate: context.coordinator))
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: wrapper.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        let inkMetalView = InkMetalView(frame: wrapper.bounds, device: nil)
        inkMetalView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(inkMetalView)
        NSLayoutConstraint.activate([
            inkMetalView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            inkMetalView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            inkMetalView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            inkMetalView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        context.coordinator.attach(canvas: canvas, inkMetalView: inkMetalView)
        context.coordinator.lastAppliedBackground = background
        context.coordinator.syncRendererFromCanvas(canvas)
        context.coordinator.lastSyncedData = drawing.dataRepresentation()

        DispatchQueue.main.async {
            canvas.becomeFirstResponder()
            context.coordinator.applyInitialOffsetIfNeeded(canvas)
            context.coordinator.syncScraps(in: canvas, with: scraps)
            context.coordinator.updateCameraMatrix()
        }
        return wrapper
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        guard let canvas = context.coordinator.canvas else { return }
        let externalData = drawing.dataRepresentation()
        if externalData != context.coordinator.lastSyncedData {
            context.coordinator.isApplyingExternalDrawing = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalDrawing = false
            context.coordinator.lastSyncedData = externalData
            context.coordinator.syncRendererFromCanvas(canvas)
        }
        canvas.tool = tool
        context.coordinator.syncBackground(in: canvas, type: background)
        context.coordinator.syncScraps(in: canvas, with: scraps)
        context.coordinator.handleResetIfNeeded(canvas)
        context.coordinator.handleUndoRedoIfNeeded(canvas)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIDropInteractionDelegate, UIPencilInteractionDelegate {
        var parent: InfiniteCanvasContainer
        var lastAppliedBackground: CanvasBackground?
        var lastSyncedData: Data?
        var isApplyingExternalDrawing = false
        weak var canvas: PKCanvasView?
        weak var inkMetalView: InkMetalView?
        private var didApplyInitialOffset = false
        private var scrapViews: [UUID: ScrapOverlayView] = [:]
        private var lastResetTrigger: UUID?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?
        private var isUserDrawing = false

        init(_ parent: InfiniteCanvasContainer) { self.parent = parent }

        func attach(canvas: PKCanvasView, inkMetalView: InkMetalView) {
            self.canvas = canvas
            self.inkMetalView = inkMetalView
        }

        func syncRendererFromCanvas(_ canvas: PKCanvasView) {
            inkMetalView?.inkRenderer.setStrokes(PKDrawingConverter.toInkStrokes(canvas.drawing))
            inkMetalView?.inkRenderer.setInProgress(nil)
            inkMetalView?.setNeedsDisplay()
        }

        // MARK: - Camera

        func updateCameraMatrix() {
            guard let canvas, let inkMetalView else { return }
            guard canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
            let viewport = SIMD2<Float>(Float(canvas.bounds.width), Float(canvas.bounds.height))
            let zoom = Float(max(canvas.zoomScale, 0.0001))
            let panInWorld = SIMD2<Float>(
                Float(canvas.contentOffset.x / canvas.zoomScale),
                Float(canvas.contentOffset.y / canvas.zoomScale)
            )
            inkMetalView.inkRenderer.cameraTransform = InkCamera.matrix(
                viewport: viewport, panInWorld: panInWorld, zoom: zoom
            )
            inkMetalView.setNeedsDisplay()
        }

        func applyInitialOffsetIfNeeded(_ canvas: PKCanvasView) {
            guard !didApplyInitialOffset else { return }
            guard canvas.bounds.size != .zero else { return }
            let saved = parent.contentOffset
            let target: CGPoint
            if saved == .zero {
                let cx = (canvas.contentSize.width - canvas.bounds.width) / 2
                let cy = (canvas.contentSize.height - canvas.bounds.height) / 2
                target = CGPoint(x: max(0, cx), y: max(0, cy))
            } else {
                target = saved
            }
            canvas.setContentOffset(target, animated: false)
            didApplyInitialOffset = true
            updateCameraMatrix()
        }

        func syncBackground(in canvas: PKCanvasView, type: CanvasBackground) {
            guard lastAppliedBackground != type else { return }
            lastAppliedBackground = type
            canvas.backgroundColor = type.uiBackgroundColor()
        }

        func handleResetIfNeeded(_ canvas: PKCanvasView) {
            guard let trigger = parent.resetTrigger, lastResetTrigger != trigger else { return }
            lastResetTrigger = trigger
            DispatchQueue.main.async { [weak canvas, weak self] in
                guard let canvas else { return }
                canvas.setZoomScale(1.0, animated: true)
                let cx = (canvas.contentSize.width - canvas.bounds.width) / 2
                let cy = (canvas.contentSize.height - canvas.bounds.height) / 2
                let target = CGPoint(x: max(0, cx), y: max(0, cy))
                canvas.setContentOffset(target, animated: true)
                self?.parent.contentOffset = target
                self?.updateCameraMatrix()
                self?.parent.onZoomChanged?(1.0)
            }
        }

        func handleUndoRedoIfNeeded(_ canvas: PKCanvasView) {
            guard parent.isMainCanvasActive else { return }
            var didFire = false
            if let t = parent.undoTrigger, lastUndoTrigger != t {
                lastUndoTrigger = t
                canvas.undoManager?.undo()
                didFire = true
            }
            if let t = parent.redoTrigger, lastRedoTrigger != t {
                lastRedoTrigger = t
                canvas.undoManager?.redo()
                didFire = true
            }
            if didFire {
                DispatchQueue.main.async { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.syncRendererFromCanvas(canvas)
                    self.parent.onUndoRedoStateChanged?(
                        canvas.undoManager?.canUndo ?? false,
                        canvas.undoManager?.canRedo ?? false
                    )
                }
            }
        }

        func syncScraps(in canvas: PKCanvasView, with scraps: [ScrapItem]) {
            let liveIDs = Set(scraps.map { $0.id })
            for (id, view) in scrapViews where !liveIDs.contains(id) {
                view.removeFromSuperview()
                scrapViews.removeValue(forKey: id)
            }
            let scale = canvas.zoomScale
            for scrap in scraps {
                if let existing = scrapViews[scrap.id] {
                    existing.update(from: scrap)
                    existing.applyZoom(scale)
                } else {
                    let view = ScrapOverlayView(scrap: scrap)
                    view.onTap = { [weak self] id in
                        self?.parent.onScrapTap?(id)
                    }
                    view.onPositionChanged = { [weak self] id, position in
                        self?.parent.onScrapMoved?(id, position)
                    }
                    view.onSizeChanged = { [weak self] id, size in
                        self?.parent.onScrapResized?(id, size)
                    }
                    view.onDeleteRequested = { [weak self] id in
                        self?.parent.onScrapDeleted?(id)
                    }
                    canvas.addSubview(view)
                    view.applyZoom(scale)
                    scrapViews[scrap.id] = view
                }
            }
        }

        // MARK: - PKCanvasViewDelegate

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isUserDrawing = true
            parent.onStrokeBegan?()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isUserDrawing = false
            inkMetalView?.inkRenderer.setInProgress(nil)
            syncRendererFromCanvas(canvasView)
            publishDrawing(canvasView.drawing)
            notifyUndoRedoState(canvasView)
            parent.onStrokeEnded?()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else { return }
            if isUserDrawing {
                if let last = canvasView.drawing.strokes.last,
                   let inkStroke = PKDrawingConverter.convert(last) {
                    inkMetalView?.inkRenderer.setInProgress(inkStroke)
                    inkMetalView?.setNeedsDisplay()
                }
            } else {
                inkMetalView?.inkRenderer.setInProgress(nil)
                syncRendererFromCanvas(canvasView)
                publishDrawing(canvasView.drawing)
                notifyUndoRedoState(canvasView)
            }
            parent.onMainCanvasActivated?()
        }

        private func publishDrawing(_ drawing: PKDrawing) {
            lastSyncedData = drawing.dataRepresentation()
            parent.drawing = drawing
        }

        private func notifyUndoRedoState(_ canvasView: PKCanvasView) {
            parent.onUndoRedoStateChanged?(
                canvasView.undoManager?.canUndo ?? false,
                canvasView.undoManager?.canRedo ?? false
            )
        }

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

        // MARK: - UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let canvas = scrollView as? PKCanvasView else { return }
            guard !scrollView.isZooming, !scrollView.isZoomBouncing else { return }
            expandIfNearEdges(canvas)
            updateCameraMatrix()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let scale = scrollView.zoomScale
            for view in scrapViews.values {
                view.applyZoom(scale)
            }
            updateCameraMatrix()
            parent.onZoomChanged?(scale)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard let canvas = scrollView as? PKCanvasView else { return }
            expandIfNearEdges(canvas)
            commitOffset(canvas)
            updateCameraMatrix()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            commitOffset(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { commitOffset(scrollView) }
        }

        private func commitOffset(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset
            if parent.contentOffset != offset {
                parent.contentOffset = offset
            }
        }

        private func expandIfNearEdges(_ canvas: PKCanvasView) {
            let margin = InfiniteCanvasContainer.expansionMargin
            let step = InfiniteCanvasContainer.expansionStep
            let cap = InfiniteCanvasContainer.maxContentDimension
            let offset = canvas.contentOffset
            let size = canvas.contentSize
            let visible = canvas.bounds.size

            var newSize = size
            var newOffset = offset

            if offset.y < margin, size.height < cap {
                newSize.height = min(cap, newSize.height + step)
                newOffset.y += (newSize.height - size.height)
            }
            if offset.x < margin, size.width < cap {
                newSize.width = min(cap, newSize.width + step)
                newOffset.x += (newSize.width - size.width)
            }
            if offset.y + visible.height > size.height - margin, size.height < cap {
                newSize.height = min(cap, newSize.height + step)
            }
            if offset.x + visible.width > size.width - margin, size.width < cap {
                newSize.width = min(cap, newSize.width + step)
            }

            if newSize != size {
                canvas.contentSize = newSize
                if newOffset != offset {
                    canvas.setContentOffset(newOffset, animated: false)
                }
            }
        }

        // MARK: - UIDropInteraction

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            if session.items.contains(where: { $0.localObject is TextScrapPayload }) { return true }
            if session.items.contains(where: { $0.localObject is ImageScrapPayload }) { return true }
            return session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_ interaction: UIDropInteraction,
                             sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let canvas = interaction.view as? PKCanvasView ?? self.canvas else { return }
            let location = session.location(in: canvas)

            if let textPayload = session.items.compactMap({ $0.localObject as? TextScrapPayload }).first {
                let payload = CanvasDropPayload(
                    kind: .text,
                    text: textPayload.text,
                    imageData: nil,
                    position: location,
                    sourcePageIndex: textPayload.pageIndex,
                    sourceRect: textPayload.pageBounds
                )
                parent.onDrop?(payload)
                return
            }

            if let imagePayload = session.items.compactMap({ $0.localObject as? ImageScrapPayload }).first {
                let payload = CanvasDropPayload(
                    kind: .image,
                    text: nil,
                    imageData: imagePayload.imageData,
                    position: location,
                    sourcePageIndex: imagePayload.pageIndex,
                    sourceRect: imagePayload.pageBounds
                )
                parent.onDrop?(payload)
                return
            }

            session.loadObjects(ofClass: NSString.self) { [weak self] items in
                guard let self,
                      let text = items.first as? String, !text.isEmpty else { return }
                let payload = CanvasDropPayload(
                    kind: .text,
                    text: text,
                    imageData: nil,
                    position: location,
                    sourcePageIndex: 0,
                    sourceRect: .zero
                )
                Task { @MainActor in
                    self.parent.onDrop?(payload)
                }
            }
        }
    }
}
