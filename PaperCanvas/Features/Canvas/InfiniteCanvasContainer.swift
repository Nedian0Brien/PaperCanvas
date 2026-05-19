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
        wrapper.backgroundColor = background.uiBackgroundColor()
        wrapper.clipsToBounds = true

        let canvas = PKCanvasView()
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput
        #else
        canvas.drawingPolicy = .pencilOnly
        #endif
        // Pattern background lives on the wrapper so PencilKit can composite
        // strokes against a transparent canvas. With an opaque pattern color,
        // PKCanvasView's stroke tiles get hidden under the pattern at zoom < 1.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
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

        let freeformLassoOverlay = CanvasFreeformLassoOverlayView()
        freeformLassoOverlay.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(freeformLassoOverlay)
        NSLayoutConstraint.activate([
            freeformLassoOverlay.topAnchor.constraint(equalTo: wrapper.topAnchor),
            freeformLassoOverlay.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            freeformLassoOverlay.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            freeformLassoOverlay.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        let freeformLassoPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleFreeformLassoPan(_:))
        )
        freeformLassoPan.delegate = context.coordinator
        freeformLassoPan.cancelsTouchesInView = true
        freeformLassoPan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(freeformLassoPan)

        context.coordinator.attach(canvas: canvas,
                                   inkMetalView: inkMetalView,
                                   rectangleLassoOverlay: rectangleLassoOverlay,
                                   rectangleLassoPan: rectangleLassoPan,
                                   freeformLassoOverlay: freeformLassoOverlay,
                                   freeformLassoPan: freeformLassoPan,
                                   activationTap: activationTap,
                                   activationPan: activationPan)
        context.coordinator.lastAppliedBackground = background
        context.coordinator.syncInkOverlayVisibility()
        context.coordinator.syncRectangleLassoState()
        context.coordinator.syncFreeformLassoState()
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
        context.coordinator.syncFreeformLassoState()
        context.coordinator.syncBackground(in: canvas, type: background)
        context.coordinator.syncScraps(in: canvas, with: scraps)
        context.coordinator.handleResetIfNeeded(canvas)
        context.coordinator.handleUndoRedoIfNeeded(canvas)
        context.coordinator.applyExternalOffsetIfNeeded(canvas)
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
        weak var freeformLassoOverlay: CanvasFreeformLassoOverlayView?
        weak var freeformLassoPan: UIPanGestureRecognizer?
        weak var activationTap: UITapGestureRecognizer?
        weak var activationPan: UIPanGestureRecognizer?
        private var didApplyInitialOffset = false
        private var scrapViews: [UUID: ScrapOverlayView] = [:]
        private var selectedScrapID: UUID?
        private var lastResetTrigger: UUID?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?
        private var isUserDrawing = false
        private var rectangleLassoStart: CGPoint?
        private var activeRectangleLassoRect: CGRect?
        private var selectedRectangleLassoIndices: Set<Int> = []
        private var activeFreeformLassoPoints: [CGPoint] = []
        private var selectedFreeformLassoIndices: Set<Int> = []
        private var movingFreeformOriginalDrawing: PKDrawing?
        private var movingFreeformLastPoint: CGPoint?
        private var freeformLassoMoveStartPoint: CGPoint?
        private var freeformLassoMoveStartTime: TimeInterval?
        private var freeformLassoMoveDidExceedTap: Bool = false
        private var movingSelectionOriginalDrawing: PKDrawing?
        private var movingSelectionLastPoint: CGPoint?
        private var rectLassoMoveStartPoint: CGPoint?
        private var rectLassoMoveStartTime: TimeInterval?
        private var rectLassoMoveDidExceedTap: Bool = false
        private static let lassoTapMovementThreshold: CGFloat = 6
        private static let lassoTapDurationThreshold: TimeInterval = 0.35
        var activeColorPickerBridge: ColorPickerBridge?

        init(_ parent: InfiniteCanvasContainer) { self.parent = parent }

        func attach(canvas: PKCanvasView,
                    inkMetalView: InkMetalView,
                    rectangleLassoOverlay: CanvasRectangleLassoOverlayView,
                    rectangleLassoPan: UIPanGestureRecognizer,
                    freeformLassoOverlay: CanvasFreeformLassoOverlayView,
                    freeformLassoPan: UIPanGestureRecognizer,
                    activationTap: UITapGestureRecognizer,
                    activationPan: UIPanGestureRecognizer) {
            self.canvas = canvas
            self.inkMetalView = inkMetalView
            self.rectangleLassoOverlay = rectangleLassoOverlay
            self.rectangleLassoPan = rectangleLassoPan
            self.freeformLassoOverlay = freeformLassoOverlay
            self.freeformLassoPan = freeformLassoPan
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

        private var wasRectangleLassoActive: Bool = false
        private var wasFreeformLassoActive: Bool = false

        func syncRectangleLassoState() {
            let isRectangleLasso = parent.toolKind == .lasso && parent.lassoMode == .rectangle
            rectangleLassoPan?.isEnabled = isRectangleLasso
            rectangleLassoOverlay?.isHidden = !isRectangleLasso
            if !isRectangleLasso {
                if wasRectangleLassoActive {
                    LassoSelectionMenu.shared.dismiss()
                }
                clearRectangleLassoSelection()
            } else {
                updateRectangleLassoOverlay()
            }
            wasRectangleLassoActive = isRectangleLasso
        }

        func syncFreeformLassoState() {
            let isFreeformLasso = parent.toolKind == .lasso && parent.lassoMode == .freeform
            freeformLassoPan?.isEnabled = isFreeformLasso
            freeformLassoOverlay?.isHidden = !isFreeformLasso
            if !isFreeformLasso {
                if wasFreeformLassoActive {
                    LassoSelectionMenu.shared.dismiss()
                }
                clearFreeformLassoSelection()
            } else {
                updateFreeformLassoOverlay()
            }
            wasFreeformLassoActive = isFreeformLasso
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

        /// Apply a programmatic content-offset change requested by the parent
        /// (e.g. a node tap that wants to recenter the canvas). We threshold
        /// because the binding is also driven by user scrolling, and a
        /// re-application during a normal scroll would fight the user.
        func applyExternalOffsetIfNeeded(_ canvas: PKCanvasView) {
            guard didApplyInitialOffset else { return }
            let current = canvas.contentOffset
            let target = parent.contentOffset
            let dx = abs(current.x - target.x)
            let dy = abs(current.y - target.y)
            guard dx > 1 || dy > 1 else { return }
            // Only programmatic when the user isn't actively scrolling.
            guard !canvas.isDragging, !canvas.isDecelerating else { return }
            canvas.setContentOffset(target, animated: true)
            updateCameraMatrix()
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
            canvas.superview?.backgroundColor = type.uiBackgroundColor()
        }

        func handleResetIfNeeded(_ canvas: PKCanvasView) {
            guard let trigger = parent.resetTrigger, lastResetTrigger != trigger else { return }
            lastResetTrigger = trigger
            let scraps = parent.scraps
            DispatchQueue.main.async { [weak canvas, weak self] in
                guard let canvas, let self else { return }
                canvas.setZoomScale(1.0, animated: true)
                let target = self.recenterTarget(in: canvas, scraps: scraps)
                canvas.setContentOffset(target, animated: true)
                self.parent.contentOffset = target
                self.updateCameraMatrix()
                self.parent.onZoomChanged?(1.0)
            }
        }

        /// Compute the content offset that centers the viewport on the user's
        /// existing content (strokes + scraps). Falls back to the geometric
        /// center of contentSize when the canvas is empty.
        private func recenterTarget(in canvas: PKCanvasView, scraps: [ScrapItem]) -> CGPoint {
            let viewport = canvas.bounds.size
            let contentSize = canvas.contentSize

            var contentBounds: CGRect = .null
            let drawingBounds = canvas.drawing.bounds
            if drawingBounds.width > 0 || drawingBounds.height > 0 {
                contentBounds = drawingBounds
            }
            for scrap in scraps {
                let rect = CGRect(
                    x: CGFloat(scrap.positionX),
                    y: CGFloat(scrap.positionY),
                    width: max(1, CGFloat(scrap.width)),
                    height: max(1, CGFloat(scrap.height))
                )
                contentBounds = contentBounds.isNull ? rect : contentBounds.union(rect)
            }

            let center: CGPoint
            if contentBounds.isNull {
                center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
            } else {
                center = CGPoint(x: contentBounds.midX, y: contentBounds.midY)
            }

            let rawX = center.x - viewport.width / 2
            let rawY = center.y - viewport.height / 2
            let maxX = max(0, contentSize.width - viewport.width)
            let maxY = max(0, contentSize.height - viewport.height)
            return CGPoint(
                x: min(maxX, max(0, rawX)),
                y: min(maxY, max(0, rawY))
            )
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
                        self?.handleScrapSelection(id)
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
                        if self?.selectedScrapID == id {
                            self?.selectedScrapID = nil
                        }
                        self?.parent.onScrapDeleted?(id)
                    }
                    canvas.addSubview(view)
                    view.applyZoom(scale)
                    scrapViews[scrap.id] = view
                }
            }
        }

        /// Keep at most one scrap selected at a time; tapping the already-selected
        /// scrap toggles it off (the tapped view has already flipped its own
        /// `visualState`, so we just have to clear the previous selection).
        func handleScrapSelection(_ tappedID: UUID) {
            let tappedView = scrapViews[tappedID]
            let isNowSelected = tappedView?.visualState == .selected
            if let previousID = selectedScrapID, previousID != tappedID {
                scrapViews[previousID]?.visualState = .normal
            }
            selectedScrapID = isNowSelected ? tappedID : nil
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
                    rectLassoMoveStartPoint = point
                    rectLassoMoveStartTime = ProcessInfo.processInfo.systemUptime
                    rectLassoMoveDidExceedTap = false
                    LassoSelectionMenu.shared.dismiss()
                    activeRectangleLassoRect = nil
                } else {
                    LassoSelectionMenu.shared.dismiss()
                    selectedRectangleLassoIndices.removeAll()
                    movingSelectionOriginalDrawing = nil
                    movingSelectionLastPoint = nil
                    rectLassoMoveStartPoint = nil
                    rectLassoMoveStartTime = nil
                    rectLassoMoveDidExceedTap = false
                    rectangleLassoStart = point
                    activeRectangleLassoRect = CGRect(origin: point, size: .zero)
                }
                updateRectangleLassoOverlay()
            case .changed:
                if movingSelectionOriginalDrawing != nil {
                    if let start = rectLassoMoveStartPoint,
                       !rectLassoMoveDidExceedTap,
                       hypot(point.x - start.x, point.y - start.y) > Self.lassoTapMovementThreshold {
                        rectLassoMoveDidExceedTap = true
                    }
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
            if gestureRecognizer === freeformLassoPan {
                return parent.toolKind == .lasso && parent.lassoMode == .freeform
            }
            if gestureRecognizer === activationPan {
                return !(parent.toolKind == .lasso)
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === rectangleLassoPan || otherGestureRecognizer === rectangleLassoPan {
                return false
            }
            if gestureRecognizer === freeformLassoPan || otherGestureRecognizer === freeformLassoPan {
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
            let startPoint = rectangleLassoStart
            let activeRect = activeRectangleLassoRect
            defer {
                rectangleLassoStart = nil
                activeRectangleLassoRect = nil
                parent.onStrokeEnded?()
                updateRectangleLassoOverlay()
            }
            guard let rect = activeRect,
                  rect.width > 4,
                  rect.height > 4 else {
                selectedRectangleLassoIndices.removeAll()
                if let startPoint, InkLassoClipboard.hasStrokes {
                    let target = startPoint
                    DispatchQueue.main.async { [weak self, weak canvas] in
                        guard let canvas else { return }
                        self?.presentRectanglePasteShortcut(at: target, in: canvas)
                    }
                }
                return
            }
            selectedRectangleLassoIndices = selectedStrokeIndices(in: canvas, intersecting: rect)
        }

        private func presentRectanglePasteShortcut(at canvasPoint: CGPoint, in canvas: PKCanvasView) {
            LassoSelectionMenu.shared.presentPasteShortcut(in: canvas, sourcePoint: canvasPoint) { [weak self, weak canvas] in
                guard let canvas else { return }
                self?.pasteRectangleSelection(at: canvasPoint, in: canvas)
            }
        }

        private func finishMovingRectangleSelection(in canvas: PKCanvasView) {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = (rectLassoMoveStartTime.map { now - $0 }) ?? .infinity
            let isTap = !rectLassoMoveDidExceedTap && elapsed <= Self.lassoTapDurationThreshold
            if isTap {
                if let original = movingSelectionOriginalDrawing {
                    isApplyingExternalDrawing = true
                    canvas.drawing = original
                    isApplyingExternalDrawing = false
                    publishDrawing(original)
                    syncRendererFromCanvas(canvas)
                }
                movingSelectionOriginalDrawing = nil
                movingSelectionLastPoint = nil
                rectLassoMoveStartPoint = nil
                rectLassoMoveStartTime = nil
                rectLassoMoveDidExceedTap = false
                parent.onStrokeEnded?()
                updateRectangleLassoOverlay()
                DispatchQueue.main.async { [weak self, weak canvas] in
                    guard let canvas else { return }
                    self?.presentRectangleSelectionMenu(in: canvas)
                }
                return
            }
            movingSelectionOriginalDrawing = nil
            movingSelectionLastPoint = nil
            rectLassoMoveStartPoint = nil
            rectLassoMoveStartTime = nil
            rectLassoMoveDidExceedTap = false
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

        // MARK: - Freeform lasso

        @objc func handleFreeformLassoPan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.toolKind == .lasso,
                  parent.lassoMode == .freeform,
                  let canvas else { return }
            let point = recognizer.location(in: canvas)
            switch recognizer.state {
            case .began:
                parent.onMainCanvasActivated?()
                parent.onStrokeBegan?()
                if let bounds = selectedFreeformLassoBounds(in: canvas),
                   bounds.insetBy(dx: -18, dy: -18).contains(point) {
                    movingFreeformOriginalDrawing = canvas.drawing
                    movingFreeformLastPoint = point
                    freeformLassoMoveStartPoint = point
                    freeformLassoMoveStartTime = ProcessInfo.processInfo.systemUptime
                    freeformLassoMoveDidExceedTap = false
                    LassoSelectionMenu.shared.dismiss()
                    activeFreeformLassoPoints = []
                } else {
                    LassoSelectionMenu.shared.dismiss()
                    selectedFreeformLassoIndices.removeAll()
                    movingFreeformOriginalDrawing = nil
                    movingFreeformLastPoint = nil
                    freeformLassoMoveStartPoint = nil
                    freeformLassoMoveStartTime = nil
                    freeformLassoMoveDidExceedTap = false
                    activeFreeformLassoPoints = [point]
                }
                updateFreeformLassoOverlay()
            case .changed:
                if movingFreeformOriginalDrawing != nil {
                    if let start = freeformLassoMoveStartPoint,
                       !freeformLassoMoveDidExceedTap,
                       hypot(point.x - start.x, point.y - start.y) > Self.lassoTapMovementThreshold {
                        freeformLassoMoveDidExceedTap = true
                    }
                    moveSelectedFreeformStrokes(to: point, in: canvas)
                } else if let last = activeFreeformLassoPoints.last {
                    if hypot(point.x - last.x, point.y - last.y) > 0.35 {
                        activeFreeformLassoPoints.append(point)
                    }
                    updateFreeformLassoOverlay()
                }
            case .ended:
                if movingFreeformOriginalDrawing != nil {
                    finishMovingFreeformSelection(in: canvas)
                } else {
                    finishFreeformSelection(in: canvas)
                }
            case .cancelled, .failed:
                cancelFreeformLasso(in: canvas)
            default:
                break
            }
        }

        private func moveSelectedFreeformStrokes(to point: CGPoint, in canvas: PKCanvasView) {
            guard let lastPoint = movingFreeformLastPoint,
                  !selectedFreeformLassoIndices.isEmpty else { return }
            let delta = CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
            guard abs(delta.dx) > 0.01 || abs(delta.dy) > 0.01 else { return }
            var strokes = canvas.drawing.strokes
            for index in selectedFreeformLassoIndices where strokes.indices.contains(index) {
                strokes[index] = strokes[index].translatedForCanvas(by: delta)
            }
            isApplyingExternalDrawing = true
            canvas.drawing = PKDrawing(strokes: strokes)
            isApplyingExternalDrawing = false
            publishDrawing(canvas.drawing)
            syncRendererFromCanvas(canvas)
            movingFreeformLastPoint = point
            updateFreeformLassoOverlay()
        }

        private func finishFreeformSelection(in canvas: PKCanvasView) {
            let points = activeFreeformLassoPoints
            defer {
                activeFreeformLassoPoints = []
                parent.onStrokeEnded?()
                updateFreeformLassoOverlay()
            }
            guard points.count >= 3 else {
                selectedFreeformLassoIndices.removeAll()
                if let tap = points.first, InkLassoClipboard.hasStrokes {
                    DispatchQueue.main.async { [weak self, weak canvas] in
                        guard let canvas else { return }
                        self?.presentFreeformPasteShortcut(at: tap, in: canvas)
                    }
                }
                return
            }
            selectedFreeformLassoIndices = freeformStrokeIndices(in: canvas, polygon: points)
            if selectedFreeformLassoIndices.isEmpty,
               let first = points.first,
               points.allSatisfy({ hypot($0.x - first.x, $0.y - first.y) <= Self.lassoTapMovementThreshold }),
               InkLassoClipboard.hasStrokes {
                DispatchQueue.main.async { [weak self, weak canvas] in
                    guard let canvas else { return }
                    self?.presentFreeformPasteShortcut(at: first, in: canvas)
                }
            }
        }

        private func presentFreeformPasteShortcut(at canvasPoint: CGPoint, in canvas: PKCanvasView) {
            LassoSelectionMenu.shared.presentPasteShortcut(in: canvas, sourcePoint: canvasPoint) { [weak self, weak canvas] in
                guard let canvas else { return }
                self?.pasteFreeformSelection(at: canvasPoint, in: canvas)
            }
        }

        private func finishMovingFreeformSelection(in canvas: PKCanvasView) {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = (freeformLassoMoveStartTime.map { now - $0 }) ?? .infinity
            let isTap = !freeformLassoMoveDidExceedTap && elapsed <= Self.lassoTapDurationThreshold
            if isTap {
                if let original = movingFreeformOriginalDrawing {
                    isApplyingExternalDrawing = true
                    canvas.drawing = original
                    isApplyingExternalDrawing = false
                    publishDrawing(original)
                    syncRendererFromCanvas(canvas)
                }
                movingFreeformOriginalDrawing = nil
                movingFreeformLastPoint = nil
                freeformLassoMoveStartPoint = nil
                freeformLassoMoveStartTime = nil
                freeformLassoMoveDidExceedTap = false
                parent.onStrokeEnded?()
                updateFreeformLassoOverlay()
                DispatchQueue.main.async { [weak self, weak canvas] in
                    guard let canvas else { return }
                    self?.presentFreeformSelectionMenu(in: canvas)
                }
                return
            }
            movingFreeformOriginalDrawing = nil
            movingFreeformLastPoint = nil
            freeformLassoMoveStartPoint = nil
            freeformLassoMoveStartTime = nil
            freeformLassoMoveDidExceedTap = false
            publishDrawing(canvas.drawing)
            notifyUndoRedoState(canvas)
            parent.onStrokeEnded?()
            updateFreeformLassoOverlay()
        }

        private func cancelFreeformLasso(in canvas: PKCanvasView) {
            if let original = movingFreeformOriginalDrawing {
                isApplyingExternalDrawing = true
                canvas.drawing = original
                isApplyingExternalDrawing = false
                publishDrawing(original)
                syncRendererFromCanvas(canvas)
            }
            activeFreeformLassoPoints = []
            movingFreeformOriginalDrawing = nil
            movingFreeformLastPoint = nil
            freeformLassoMoveStartPoint = nil
            freeformLassoMoveStartTime = nil
            freeformLassoMoveDidExceedTap = false
            parent.onStrokeEnded?()
            updateFreeformLassoOverlay()
        }

        private func clearFreeformLassoSelection() {
            activeFreeformLassoPoints = []
            selectedFreeformLassoIndices.removeAll()
            movingFreeformOriginalDrawing = nil
            movingFreeformLastPoint = nil
            freeformLassoOverlay?.update(activeLassoPoints: nil,
                                         selectedContentRect: nil,
                                         in: nil)
        }

        private func updateFreeformLassoOverlay() {
            guard let canvas else { return }
            freeformLassoOverlay?.update(
                activeLassoPoints: activeFreeformLassoPoints.isEmpty ? nil : activeFreeformLassoPoints,
                selectedContentRect: selectedFreeformLassoBounds(in: canvas),
                in: canvas
            )
        }

        private func selectedFreeformLassoBounds(in canvas: PKCanvasView) -> CGRect? {
            var union: CGRect?
            for index in selectedFreeformLassoIndices where canvas.drawing.strokes.indices.contains(index) {
                guard let inkStroke = PKDrawingConverter.convert(canvas.drawing.strokes[index]) else { continue }
                union = union.map { $0.union(inkStroke.boundingBox) } ?? inkStroke.boundingBox
            }
            return union
        }

        private func freeformStrokeIndices(in canvas: PKCanvasView, polygon: [CGPoint]) -> Set<Int> {
            guard polygon.count >= 3 else { return [] }
            let bounds = LassoGeometry.bounds(for: polygon)
            return Set(canvas.drawing.strokes.enumerated().compactMap { index, pkStroke in
                guard let inkStroke = PKDrawingConverter.convert(pkStroke),
                      inkStroke.boundingBox.intersects(bounds) else { return nil }
                if LassoGeometry.polygonContains(CGPoint(x: inkStroke.boundingBox.midX,
                                                          y: inkStroke.boundingBox.midY),
                                                  polygon: polygon) {
                    return index
                }
                for point in inkStroke.points {
                    if bounds.contains(point.location),
                       LassoGeometry.polygonContains(point.location, polygon: polygon) {
                        return index
                    }
                }
                return nil
            })
        }

        // MARK: - Selection context menu (freeform lasso)

        private func presentFreeformSelectionMenu(in canvas: PKCanvasView) {
            guard let bounds = selectedFreeformLassoBounds(in: canvas) else { return }
            let inset = bounds.insetBy(dx: -6, dy: -6)
            let actions = LassoMenuActions(
                canPaste: InkLassoClipboard.hasStrokes,
                onCut: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.cutFreeformSelection(in: canvas)
                },
                onCopy: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.copyFreeformSelection(in: canvas)
                },
                onPaste: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.pasteFreeformSelection(at: nil, in: canvas)
                },
                onRecolor: { [weak self, weak canvas] color in
                    guard let self, let canvas else { return }
                    self.recolorFreeformSelection(color, in: canvas)
                },
                onPickCustomColor: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.presentFreeformCustomColorPicker(in: canvas)
                },
                onDelete: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.deleteFreeformSelection(in: canvas)
                }
            )
            LassoSelectionMenu.shared.present(in: canvas, sourceRect: inset, actions: actions)
        }

        private func copyFreeformSelection(in canvas: PKCanvasView) {
            let strokes = selectedFreeformLassoIndices.sorted().compactMap { idx -> InkStroke? in
                guard canvas.drawing.strokes.indices.contains(idx) else { return nil }
                return PKDrawingConverter.convert(canvas.drawing.strokes[idx])
            }
            InkLassoClipboard.copy(strokes)
        }

        private func cutFreeformSelection(in canvas: PKCanvasView) {
            copyFreeformSelection(in: canvas)
            deleteFreeformSelection(in: canvas)
        }

        private func deleteFreeformSelection(in canvas: PKCanvasView) {
            guard !selectedFreeformLassoIndices.isEmpty else { return }
            let before = canvas.drawing
            var strokes = canvas.drawing.strokes
            for index in selectedFreeformLassoIndices.sorted(by: >)
            where strokes.indices.contains(index) {
                strokes.remove(at: index)
            }
            applyDrawing(PKDrawing(strokes: strokes), before: before, in: canvas)
            selectedFreeformLassoIndices.removeAll()
            updateFreeformLassoOverlay()
        }

        private func recolorFreeformSelection(_ color: Color, in canvas: PKCanvasView) {
            guard !selectedFreeformLassoIndices.isEmpty else { return }
            let before = canvas.drawing
            var strokes = canvas.drawing.strokes
            let uiColor = UIColor(color)
            for index in selectedFreeformLassoIndices where strokes.indices.contains(index) {
                let original = strokes[index]
                let newInk = PKInk(original.ink.inkType, color: uiColor)
                strokes[index] = PKStroke(
                    ink: newInk,
                    path: original.path,
                    transform: original.transform,
                    mask: original.mask
                )
            }
            applyDrawing(PKDrawing(strokes: strokes), before: before, in: canvas)
            updateFreeformLassoOverlay()
        }

        func pasteFreeformSelection(at canvasPoint: CGPoint?, in canvas: PKCanvasView) {
            guard let inkStrokes = InkLassoClipboard.paste(), !inkStrokes.isEmpty else { return }
            let before = canvas.drawing
            let union = inkStrokes.dropFirst().reduce(inkStrokes[0].boundingBox) { $0.union($1.boundingBox) }
            let center = CGPoint(x: union.midX, y: union.midY)
            let target: CGPoint
            if let canvasPoint {
                target = canvasPoint
            } else if let existing = selectedFreeformLassoBounds(in: canvas) {
                target = CGPoint(x: existing.midX + 20, y: existing.midY + 20)
            } else {
                target = CGPoint(
                    x: canvas.contentOffset.x / canvas.zoomScale + canvas.bounds.midX / canvas.zoomScale,
                    y: canvas.contentOffset.y / canvas.zoomScale + canvas.bounds.midY / canvas.zoomScale
                )
            }
            let delta = CGVector(dx: target.x - center.x, dy: target.y - center.y)
            let translated = inkStrokes.map { $0.translated(by: delta) }
            let pasted = translated.compactMap { PKDrawingConverter.makePKStroke(from: $0) }
            guard !pasted.isEmpty else { return }
            let baseCount = canvas.drawing.strokes.count
            applyDrawing(PKDrawing(strokes: canvas.drawing.strokes + pasted), before: before, in: canvas)
            selectedFreeformLassoIndices = Set(baseCount..<(baseCount + pasted.count))
            updateFreeformLassoOverlay()
        }

        private func presentFreeformCustomColorPicker(in canvas: PKCanvasView) {
            guard let presenter = canvas.findTopPresenter() else { return }
            let picker = UIColorPickerViewController()
            picker.supportsAlpha = false
            let bridge = ColorPickerBridge { [weak self, weak canvas] color in
                guard let self else { return }
                self.activeColorPickerBridge = nil
                if let color, let canvas {
                    self.recolorFreeformSelection(Color(color), in: canvas)
                }
            }
            picker.delegate = bridge
            activeColorPickerBridge = bridge
            presenter.present(picker, animated: true)
        }

        // MARK: - Selection context menu (rectangle lasso)

        private func presentRectangleSelectionMenu(in canvas: PKCanvasView) {
            guard let bounds = selectedRectangleLassoBounds(in: canvas) else { return }
            let inset = bounds.insetBy(dx: -6, dy: -6)
            let actions = LassoMenuActions(
                canPaste: InkLassoClipboard.hasStrokes,
                onCut: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.cutRectangleSelection(in: canvas)
                },
                onCopy: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.copyRectangleSelection(in: canvas)
                },
                onPaste: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.pasteRectangleSelection(at: nil, in: canvas)
                },
                onRecolor: { [weak self, weak canvas] color in
                    guard let self, let canvas else { return }
                    self.recolorRectangleSelection(color, in: canvas)
                },
                onPickCustomColor: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.presentRectangleCustomColorPicker(in: canvas)
                },
                onDelete: { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    self.deleteRectangleSelection(in: canvas)
                }
            )
            LassoSelectionMenu.shared.present(in: canvas, sourceRect: inset, actions: actions)
        }

        private func copyRectangleSelection(in canvas: PKCanvasView) {
            let indices = selectedRectangleLassoIndices.sorted()
            let strokes = indices.compactMap { idx -> InkStroke? in
                guard canvas.drawing.strokes.indices.contains(idx) else { return nil }
                return PKDrawingConverter.convert(canvas.drawing.strokes[idx])
            }
            InkLassoClipboard.copy(strokes)
        }

        private func cutRectangleSelection(in canvas: PKCanvasView) {
            copyRectangleSelection(in: canvas)
            deleteRectangleSelection(in: canvas)
        }

        private func deleteRectangleSelection(in canvas: PKCanvasView) {
            guard !selectedRectangleLassoIndices.isEmpty else { return }
            let before = canvas.drawing
            var strokes = canvas.drawing.strokes
            for index in selectedRectangleLassoIndices.sorted(by: >)
            where strokes.indices.contains(index) {
                strokes.remove(at: index)
            }
            let after = PKDrawing(strokes: strokes)
            applyDrawing(after, before: before, in: canvas)
            selectedRectangleLassoIndices.removeAll()
            updateRectangleLassoOverlay()
        }

        private func recolorRectangleSelection(_ color: Color, in canvas: PKCanvasView) {
            guard !selectedRectangleLassoIndices.isEmpty else { return }
            let before = canvas.drawing
            var strokes = canvas.drawing.strokes
            let uiColor = UIColor(color)
            for index in selectedRectangleLassoIndices where strokes.indices.contains(index) {
                let original = strokes[index]
                let newInk = PKInk(original.ink.inkType, color: uiColor)
                strokes[index] = PKStroke(
                    ink: newInk,
                    path: original.path,
                    transform: original.transform,
                    mask: original.mask
                )
            }
            applyDrawing(PKDrawing(strokes: strokes), before: before, in: canvas)
            updateRectangleLassoOverlay()
        }

        func pasteRectangleSelection(at canvasPoint: CGPoint?, in canvas: PKCanvasView) {
            guard let inkStrokes = InkLassoClipboard.paste(), !inkStrokes.isEmpty else { return }
            let before = canvas.drawing
            let union = inkStrokes.dropFirst().reduce(inkStrokes[0].boundingBox) { $0.union($1.boundingBox) }
            let center = CGPoint(x: union.midX, y: union.midY)
            let target: CGPoint
            if let canvasPoint {
                target = canvasPoint
            } else if let existing = selectedRectangleLassoBounds(in: canvas) {
                target = CGPoint(x: existing.midX + 20, y: existing.midY + 20)
            } else {
                target = CGPoint(
                    x: canvas.contentOffset.x / canvas.zoomScale + canvas.bounds.midX / canvas.zoomScale,
                    y: canvas.contentOffset.y / canvas.zoomScale + canvas.bounds.midY / canvas.zoomScale
                )
            }
            let delta = CGVector(dx: target.x - center.x, dy: target.y - center.y)
            let translated = inkStrokes.map { $0.translated(by: delta) }
            let pasted = translated.compactMap { PKDrawingConverter.makePKStroke(from: $0) }
            guard !pasted.isEmpty else { return }
            let after = PKDrawing(strokes: canvas.drawing.strokes + pasted)
            let baseCount = canvas.drawing.strokes.count
            applyDrawing(after, before: before, in: canvas)
            selectedRectangleLassoIndices = Set(baseCount..<(baseCount + pasted.count))
            updateRectangleLassoOverlay()
        }

        private func presentRectangleCustomColorPicker(in canvas: PKCanvasView) {
            guard let presenter = canvas.findTopPresenter() else { return }
            let picker = UIColorPickerViewController()
            picker.supportsAlpha = false
            let bridge = ColorPickerBridge { [weak self, weak canvas] color in
                guard let self else { return }
                self.activeColorPickerBridge = nil
                if let color, let canvas {
                    self.recolorRectangleSelection(Color(color), in: canvas)
                }
            }
            picker.delegate = bridge
            activeColorPickerBridge = bridge
            presenter.present(picker, animated: true)
        }

        fileprivate func applyDrawing(_ drawing: PKDrawing,
                                      before: PKDrawing,
                                      in canvas: PKCanvasView) {
            isApplyingExternalDrawing = true
            canvas.drawing = drawing
            isApplyingExternalDrawing = false
            publishDrawing(drawing)
            syncRendererFromCanvas(canvas)
            canvas.undoManager?.registerUndo(withTarget: self) { [weak canvas] coord in
                guard let canvas else { return }
                coord.applyDrawing(before, before: drawing, in: canvas)
            }
            notifyUndoRedoState(canvas)
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
            updateFreeformLassoOverlay()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.onMainCanvasActivated?()
            let scale = scrollView.zoomScale
            for view in scrapViews.values {
                view.applyZoom(scale)
            }
            updateCameraMatrix()
            updateRectangleLassoOverlay()
            updateFreeformLassoOverlay()
            parent.onZoomChanged?(scale)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            guard let canvas = scrollView as? PKCanvasView else { return }
            expandIfNearEdges(canvas)
            commitOffset(canvas)
            updateCameraMatrix()
            updateRectangleLassoOverlay()
            updateFreeformLassoOverlay()
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
            if session.items.contains(where: { $0.localObject is AnchorDragPayload }) { return true }
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

            if let anchorPayload = session.items.compactMap({ $0.localObject as? AnchorDragPayload }).first {
                let payload = CanvasDropPayload(
                    kind: anchorPayload.scrapKind,
                    text: anchorPayload.text,
                    imageData: anchorPayload.imageData,
                    position: location,
                    sourcePageIndex: anchorPayload.pageIndex,
                    sourceRect: anchorPayload.pageRect,
                    anchorKind: anchorPayload.anchorKind,
                    anchorID: anchorPayload.anchorID
                )
                parent.onDrop?(payload)
                return
            }

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

final class CanvasFreeformLassoOverlayView: UIView {
    private var localActivePoints: [CGPoint] = []
    private var localSelectedRect: CGRect?

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

    func update(activeLassoPoints: [CGPoint]?,
                selectedContentRect: CGRect?,
                in canvas: PKCanvasView?) {
        if let canvas {
            localActivePoints = activeLassoPoints?.map { canvas.convert($0, to: self) } ?? []
            localSelectedRect = selectedContentRect.map { canvas.convert($0.insetBy(dx: -6, dy: -6), to: self).standardized }
        } else {
            localActivePoints = []
            localSelectedRect = nil
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if let localSelectedRect, localSelectedRect.width > 0, localSelectedRect.height > 0 {
            context.saveGState()
            context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.9).cgColor)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.08).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [7, 4])
            let path = UIBezierPath(roundedRect: localSelectedRect, cornerRadius: 8).cgPath
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }
        if localActivePoints.count >= 2 {
            context.saveGState()
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(1.7)
            context.setLineDash(phase: 0, lengths: [6, 4])
            let path = UIBezierPath()
            path.move(to: localActivePoints[0])
            for point in localActivePoints.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path.cgPath)
            context.strokePath()
            context.restoreGState()
        }
    }
}

enum LassoGeometry {
    static func bounds(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func polygonContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
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
}

extension PKStroke {
    func translatedForCanvas(by delta: CGVector) -> PKStroke {
        var copy = self
        copy.transform = copy.transform.translatedBy(x: delta.dx, y: delta.dy)
        return copy
    }
}
