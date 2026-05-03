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

    static let defaultContentSize = CGSize(width: 4000, height: 4000)
    static let expansionMargin: CGFloat = 600
    static let expansionStep: CGFloat = 1500
    static let maxContentDimension: CGFloat = 30000

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
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
        canvas.drawing = drawing
        canvas.tool = tool
        canvas.addInteraction(UIDropInteraction(delegate: context.coordinator))
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)

        context.coordinator.lastAppliedBackground = background

        DispatchQueue.main.async {
            canvas.becomeFirstResponder()
            context.coordinator.applyInitialOffsetIfNeeded(canvas)
            context.coordinator.syncScraps(in: canvas, with: scraps)
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if uiView.drawing != drawing { uiView.drawing = drawing }
        uiView.tool = tool
        context.coordinator.syncBackground(in: uiView, type: background)
        context.coordinator.syncScraps(in: uiView, with: scraps)
        context.coordinator.handleResetIfNeeded(uiView)
        context.coordinator.handleUndoRedoIfNeeded(uiView)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIDropInteractionDelegate, UIPencilInteractionDelegate {
        var parent: InfiniteCanvasContainer
        var lastAppliedBackground: CanvasBackground?
        private var didApplyInitialOffset = false
        private var scrapViews: [UUID: ScrapOverlayView] = [:]
        private var lastResetTrigger: UUID?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?

        init(_ parent: InfiniteCanvasContainer) { self.parent = parent }

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

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.onMainCanvasActivated?()
            parent.onUndoRedoStateChanged?(
                canvasView.undoManager?.canUndo ?? false,
                canvasView.undoManager?.canRedo ?? false
            )
            parent.drawing = canvasView.drawing
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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let canvas = scrollView as? PKCanvasView else { return }
            expandIfNearEdges(canvas)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let scale = scrollView.zoomScale
            for view in scrapViews.values {
                view.applyZoom(scale)
            }
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
            guard let canvas = interaction.view else { return }
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
