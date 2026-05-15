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
    let toolKind: ToolKind
    let lassoMode: LassoMode
    let prefersNativeToolRendering: Bool
    let undoTrigger: UUID?
    let redoTrigger: UUID?
    let isMainCanvasActive: Bool
    var background: CanvasBackground = .dots
    var onScrapTap: ((UUID) -> Void)? = nil
    var onDrop: ((CanvasDropPayload) -> Void)? = nil
    var onScrapMoved: ((UUID, CGPoint) -> Void)? = nil
    var onScrapResized: ((UUID, CGSize) -> Void)? = nil
    var onScrapEditRequested: ((UUID) -> Void)? = nil
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
        let activationTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleCanvasTouchActivation(_:))
        )
        activationTap.delegate = context.coordinator
        activationTap.cancelsTouchesInView = false
        canvas.addGestureRecognizer(activationTap)
        let activationPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleCanvasTouchActivation(_:))
        )
        activationPan.delegate = context.coordinator
        activationPan.cancelsTouchesInView = false
        canvas.addGestureRecognizer(activationPan)

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

        let rectangleLassoOverlay = CanvasRectangleLassoOverlayView()
        rectangleLassoOverlay.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(rectangleLassoOverlay)
        NSLayoutConstraint.activate([
            rectangleLassoOverlay.topAnchor.constraint(equalTo: wrapper.topAnchor),
            rectangleLassoOverlay.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            rectangleLassoOverlay.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            rectangleLassoOverlay.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        let rectangleLassoPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRectangleLassoPan(_:))
        )
        rectangleLassoPan.delegate = context.coordinator
        rectangleLassoPan.cancelsTouchesInView = true
        canvas.addGestureRecognizer(rectangleLassoPan)

        context.coordinator.attach(canvas: canvas,
                                   inkMetalView: inkMetalView,
                                   rectangleLassoOverlay: rectangleLassoOverlay,
                                   rectangleLassoPan: rectangleLassoPan,
                                   activationTap: activationTap,
                                   activationPan: activationPan)
        context.coordinator.lastAppliedBackground = background
        context.coordinator.syncInkOverlayVisibility()
        context.coordinator.syncRectangleLassoState()
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
        context.coordinator.syncInkOverlayVisibility()
        context.coordinator.syncRectangleLassoState()
        context.coordinator.syncBackground(in: canvas, type: background)
        context.coordinator.syncScraps(in: canvas, with: scraps)
        context.coordinator.handleResetIfNeeded(canvas)
        context.coordinator.handleUndoRedoIfNeeded(canvas)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIDropInteractionDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var parent: InfiniteCanvasContainer
        var lastAppliedBackground: CanvasBackground?
        var lastSyncedData: Data?
        var isApplyingExternalDrawing = false
        weak var canvas: PKCanvasView?
        weak var inkMetalView: InkMetalView?
        weak var rectangleLassoOverlay: CanvasRectangleLassoOverlayView?
        weak var rectangleLassoPan: UIPanGestureRecognizer?
        weak var activationTap: UITapGestureRecognizer?
        weak var activationPan: UIPanGestureRecognizer?
        private var didApplyInitialOffset = false
        private var scrapViews: [UUID: ScrapOverlayView] = [:]
        private var lastResetTrigger: UUID?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?
        private var isUserDrawing = false
        private var rectangleLassoStart: CGPoint?
        private var activeRectangleLassoRect: CGRect?
        private var selectedRectangleLassoIndices: Set<Int> = []
        private var movingSelectionOriginalDrawing: PKDrawing?
        private var movingSelectionLastPoint: CGPoint?

        init(_ parent: InfiniteCanvasContainer) { self.parent = parent }

        func attach(canvas: PKCanvasView,
                    inkMetalView: InkMetalView,
                    rectangleLassoOverlay: CanvasRectangleLassoOverlayView,
                    rectangleLassoPan: UIPanGestureRecognizer,
                    activationTap: UITapGestureRecognizer,
                    activationPan: UIPanGestureRecognizer) {
            self.canvas = canvas
            self.inkMetalView = inkMetalView
            self.rectangleLassoOverlay = rectangleLassoOverlay
            self.rectangleLassoPan = rectangleLassoPan
            self.activationTap = activationTap
            self.activationPan = activationPan
        }

        func syncRendererFromCanvas(_ canvas: PKCanvasView) {
            inkMetalView?.inkRenderer.setStrokes(PKDrawingConverter.toInkStrokes(canvas.drawing))
            inkMetalView?.inkRenderer.setInProgress(nil)
            inkMetalView?.setNeedsDisplay()
        }

        func syncInkOverlayVisibility() {
            inkMetalView?.isHidden = parent.prefersNativeToolRendering
        }

        func syncRectangleLassoState() {
            let isRectangleLasso = parent.toolKind == .lasso && parent.lassoMode == .rectangle
            rectangleLassoPan?.isEnabled = isRectangleLasso
            rectangleLassoOverlay?.isHidden = !isRectangleLasso
            if !isRectangleLasso {
                clearRectangleLassoSelection()
            } else {
                updateRectangleLassoOverlay()
            }
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
                    view.onEditRequested = { [weak self] id in
                        self?.parent.onScrapEditRequested?(id)
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
            parent.onMainCanvasActivated?()
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

        @objc func handleCanvasTouchActivation(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .ended {
                parent.onMainCanvasActivated?()
            }
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

        // MARK: - Rectangle lasso

        @objc func handleRectangleLassoPan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.toolKind == .lasso,
                  parent.lassoMode == .rectangle,
                  let canvas else { return }
            let point = recognizer.location(in: canvas)
            switch recognizer.state {
            case .began:
                parent.onMainCanvasActivated?()
                parent.onStrokeBegan?()
                if let selectionBounds = selectedRectangleLassoBounds(in: canvas),
                   selectionBounds.insetBy(dx: -18, dy: -18).contains(point) {
                    movingSelectionOriginalDrawing = canvas.drawing
                    movingSelectionLastPoint = point
                    activeRectangleLassoRect = nil
                } else {
                    selectedRectangleLassoIndices.removeAll()
                    movingSelectionOriginalDrawing = nil
                    movingSelectionLastPoint = nil
                    rectangleLassoStart = point
                    activeRectangleLassoRect = CGRect(origin: point, size: .zero)
                }
                updateRectangleLassoOverlay()
            case .changed:
                if movingSelectionOriginalDrawing != nil {
                    moveSelectedRectangleLassoStrokes(to: point, in: canvas)
                } else if let start = rectangleLassoStart {
                    activeRectangleLassoRect = CGRect(
                        x: min(start.x, point.x),
                        y: min(start.y, point.y),
                        width: abs(start.x - point.x),
                        height: abs(start.y - point.y)
                    )
                    updateRectangleLassoOverlay()
                }
            case .ended:
                if movingSelectionOriginalDrawing != nil {
                    finishMovingRectangleSelection(in: canvas)
                } else {
                    finishRectangleSelection(in: canvas)
                }
            case .cancelled, .failed:
                cancelRectangleLasso(in: canvas)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === rectangleLassoPan {
                return parent.toolKind == .lasso && parent.lassoMode == .rectangle
            }
            if gestureRecognizer === activationPan {
                return !(parent.toolKind == .lasso && parent.lassoMode == .rectangle)
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === rectangleLassoPan || otherGestureRecognizer === rectangleLassoPan {
                return false
            }
            return true
        }

        private func moveSelectedRectangleLassoStrokes(to point: CGPoint, in canvas: PKCanvasView) {
            guard let lastPoint = movingSelectionLastPoint,
                  !selectedRectangleLassoIndices.isEmpty else { return }
            let delta = CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
            guard abs(delta.dx) > 0.01 || abs(delta.dy) > 0.01 else { return }
            var strokes = canvas.drawing.strokes
            for index in selectedRectangleLassoIndices where strokes.indices.contains(index) {
                strokes[index] = strokes[index].translatedForCanvas(by: delta)
            }
            isApplyingExternalDrawing = true
            canvas.drawing = PKDrawing(strokes: strokes)
            isApplyingExternalDrawing = false
            publishDrawing(canvas.drawing)
            syncRendererFromCanvas(canvas)
            movingSelectionLastPoint = point
            updateRectangleLassoOverlay()
        }

        private func finishRectangleSelection(in canvas: PKCanvasView) {
            defer {
                rectangleLassoStart = nil
                activeRectangleLassoRect = nil
                parent.onStrokeEnded?()
                updateRectangleLassoOverlay()
            }
            guard let rect = activeRectangleLassoRect,
                  rect.width > 4,
                  rect.height > 4 else {
                selectedRectangleLassoIndices.removeAll()
                return
            }
            selectedRectangleLassoIndices = selectedStrokeIndices(in: canvas, intersecting: rect)
        }

        private func finishMovingRectangleSelection(in canvas: PKCanvasView) {
            movingSelectionOriginalDrawing = nil
            movingSelectionLastPoint = nil
            publishDrawing(canvas.drawing)
            notifyUndoRedoState(canvas)
            parent.onStrokeEnded?()
            updateRectangleLassoOverlay()
        }

        private func cancelRectangleLasso(in canvas: PKCanvasView) {
            if let original = movingSelectionOriginalDrawing {
                isApplyingExternalDrawing = true
                canvas.drawing = original
                isApplyingExternalDrawing = false
                publishDrawing(original)
                syncRendererFromCanvas(canvas)
            }
            rectangleLassoStart = nil
            activeRectangleLassoRect = nil
            movingSelectionOriginalDrawing = nil
            movingSelectionLastPoint = nil
            parent.onStrokeEnded?()
            updateRectangleLassoOverlay()
        }

        private func clearRectangleLassoSelection() {
            rectangleLassoStart = nil
            activeRectangleLassoRect = nil
            selectedRectangleLassoIndices.removeAll()
            movingSelectionOriginalDrawing = nil
            movingSelectionLastPoint = nil
            rectangleLassoOverlay?.update(activeContentRect: nil,
                                          selectedContentRect: nil,
                                          in: nil)
        }

        private func updateRectangleLassoOverlay() {
            guard let canvas else { return }
            rectangleLassoOverlay?.update(activeContentRect: activeRectangleLassoRect,
                                          selectedContentRect: selectedRectangleLassoBounds(in: canvas),
                                          in: canvas)
        }

        private func selectedStrokeIndices(in canvas: PKCanvasView, intersecting rect: CGRect) -> Set<Int> {
            Set(canvas.drawing.strokes.enumerated().compactMap { index, pkStroke in
                guard let inkStroke = PKDrawingConverter.convert(pkStroke),
                      self.stroke(inkStroke, intersects: rect) else { return nil }
                return index
            })
        }

        private func selectedRectangleLassoBounds(in canvas: PKCanvasView) -> CGRect? {
            var union: CGRect?
            for index in selectedRectangleLassoIndices where canvas.drawing.strokes.indices.contains(index) {
                guard let inkStroke = PKDrawingConverter.convert(canvas.drawing.strokes[index]) else { continue }
                union = union.map { $0.union(inkStroke.boundingBox) } ?? inkStroke.boundingBox
            }
            return union
        }

        private func stroke(_ stroke: InkStroke, intersects rect: CGRect) -> Bool {
            let expanded = rect.insetBy(dx: -stroke.baseWidth * 0.5, dy: -stroke.baseWidth * 0.5)
            guard stroke.boundingBox.intersects(expanded) else { return false }
            return stroke.points.contains { expanded.contains($0.location) }
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
            parent.onMainCanvasActivated?()
            expandIfNearEdges(canvas)
            updateCameraMatrix()
            updateRectangleLassoOverlay()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.onMainCanvasActivated?()
            let scale = scrollView.zoomScale
            for view in scrapViews.values {
                view.applyZoom(scale)
            }
            updateCameraMatrix()
            updateRectangleLassoOverlay()
            parent.onZoomChanged?(scale)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard let canvas = scrollView as? PKCanvasView else { return }
            expandIfNearEdges(canvas)
            commitOffset(canvas)
            updateCameraMatrix()
            updateRectangleLassoOverlay()
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

final class CanvasRectangleLassoOverlayView: UIView {
    private var activeRect: CGRect?
    private var selectedRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func update(activeContentRect: CGRect?,
                selectedContentRect: CGRect?,
                in canvas: PKCanvasView?) {
        if let canvas {
            activeRect = activeContentRect.map { canvas.convert($0, to: self).standardized }
            selectedRect = selectedContentRect.map { canvas.convert($0.insetBy(dx: -6, dy: -6), to: self).standardized }
        } else {
            activeRect = nil
            selectedRect = nil
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if let selectedRect {
            draw(rect: selectedRect,
                 stroke: UIColor.systemBlue.withAlphaComponent(0.9),
                 fill: UIColor.systemBlue.withAlphaComponent(0.08),
                 in: context)
        }
        if let activeRect {
            draw(rect: activeRect,
                 stroke: UIColor.systemBlue,
                 fill: UIColor.systemBlue.withAlphaComponent(0.04),
                 in: context)
        }
    }

    private func draw(rect: CGRect, stroke: UIColor, fill: UIColor, in context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.setStrokeColor(stroke.cgColor)
        context.setFillColor(fill.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [7, 4])
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
}

private extension PKStroke {
    func translatedForCanvas(by delta: CGVector) -> PKStroke {
        var copy = self
        copy.transform = copy.transform.translatedBy(x: delta.dx, y: delta.dy)
        return copy
    }
}
