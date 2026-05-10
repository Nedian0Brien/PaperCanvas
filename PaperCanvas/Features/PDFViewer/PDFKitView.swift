import SwiftUI
import PDFKit
import UIKit

struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var navigationTarget: PDFNavigationTarget?
    @Binding var pageInkStrokes: [Int: [InkStroke]]
    let palette: PaletteState
    var onRegionCaptured: ((Int, CGRect, UIImage) -> Void)? = nil

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
        pdfView.document = document
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.addInteraction(UIDragInteraction(delegate: context.coordinator))

        let inkRenderView = PDFInkRenderView()
        inkRenderView.translatesAutoresizingMaskIntoConstraints = false
        inkRenderView.isUserInteractionEnabled = false

        let hoverIndicatorView = PencilHoverIndicatorView()
        hoverIndicatorView.isUserInteractionEnabled = false

        let pencilInput = PDFPencilInputGestureRecognizer()
        pdfView.addGestureRecognizer(pencilInput)

        wrapper.addSubview(pdfView)
        wrapper.addSubview(inkRenderView)
        wrapper.addSubview(hoverIndicatorView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            inkRenderView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            inkRenderView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            inkRenderView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            inkRenderView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        ])

        context.coordinator.attach(wrapper: wrapper,
                                   pdfView: pdfView,
                                   inkRenderView: inkRenderView,
                                   hoverIndicatorView: hoverIndicatorView,
                                   pencilInput: pencilInput)

        let marquee = RegionMarqueeController(pdfView: pdfView)
        marquee.onRegionCaptured = { [weak coord = context.coordinator] pageIdx, rect, img in
            coord?.parent.onRegionCaptured?(pageIdx, rect, img)
        }
        context.coordinator.regionMarquee = marquee

        DispatchQueue.main.async {
            if let page = document.page(at: currentPageIndex) {
                pdfView.go(to: page)
            }
            context.coordinator.rebuildRenderedInk()
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
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var parent: PDFKitView
        var lastConsumedTargetID: UUID?
        var regionMarquee: RegionMarqueeController?

        private weak var wrapper: UIView?
        weak var hostPDFView: PDFView?
        private weak var inkRenderView: PDFInkRenderView?
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
        private var outlineCache: [PDFInkOutlineCacheKey: CGPath] = [:]

        private var lastActivePageIndex: Int?
        private var lastUndoTrigger: UUID?
        private var lastRedoTrigger: UUID?
        private var undoStack: [PDFInkUndoAction] = []
        private var redoStack: [PDFInkUndoAction] = []

        private var activePageIndex: Int?
        private var activeStroke: InkStroke?
        private var activeStrokeStartTime: TimeInterval?

        init(_ parent: PDFKitView) { self.parent = parent }

        fileprivate func attach(wrapper: UIView,
                                pdfView: PDFView,
                                inkRenderView: PDFInkRenderView,
                                hoverIndicatorView: PencilHoverIndicatorView,
                                pencilInput: PDFPencilInputGestureRecognizer) {
            self.wrapper = wrapper
            self.hostPDFView = pdfView
            self.inkRenderView = inkRenderView
            self.hoverIndicatorView = hoverIndicatorView
            self.pencilInput = pencilInput
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
                self?.rebuildRenderedInk()
            }
        }

        func detach() {
            stopDisplayLink()
            detachScrollObservers()
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
            if let visiblePagesObserver { NotificationCenter.default.removeObserver(visiblePagesObserver) }
            pageObserver = nil
            scaleObserver = nil
            visiblePagesObserver = nil
            pencilInput?.onTouches = nil
            hoverIndicatorView?.hide()
            clearTransientState()
        }

        func clearTransientState() {
            lastViewportKey = ""
            lastStrokeSignature = ""
            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = nil
            lastActivePageIndex = nil
            undoStack.removeAll()
            redoStack.removeAll()
            outlineCache.removeAll()
            publishPDFUndoRedoState(canUndo: false, canRedo: false)
            inkRenderView?.strokes = []
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

        private func beginStroke(with touches: [UITouch]) {
            guard parent.palette.tool != .lasso,
                  let touch = touches.first,
                  let sample = makeInkPoint(from: touch, startTime: touch.timestamp) else { return }
            activePageIndex = sample.pageIndex
            activeStrokeStartTime = touch.timestamp
            lastActivePageIndex = sample.pageIndex
            parent.palette.lastActiveCanvas = .pdfInk
            parent.palette.isStrokeInProgress = true
            hoverIndicatorView?.hide()

            activeStroke = InkStroke(
                tool: currentInkTool,
                color: currentInkColor,
                baseWidth: parent.palette.width,
                points: [sample.point]
            )
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
            rebuildRenderedInk()
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
                erase(with: stroke, pageIndex: pageIndex)
            case .pen, .gelPen, .fountainPen, .brushPen, .pencil, .marker, .highlighter:
                appendCommittedStroke(stroke, pageIndex: pageIndex)
            }

            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = nil
            parent.palette.isStrokeInProgress = false
            rebuildRenderedInk()
        }

        private func cancelActiveStroke() {
            activePageIndex = nil
            activeStroke = nil
            activeStrokeStartTime = nil
            parent.palette.isStrokeInProgress = false
            rebuildRenderedInk()
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
            let after = before.filter { !stroke($0, intersectsEraser: eraserStroke, radius: radius) }
            guard after.count != before.count else { return }
            applyReplacement(pageIndex: pageIndex, before: before, after: after, recordsUndo: true)
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
            updateUndoRedoState()
            rebuildRenderedInk()
        }

        private func setStrokes(_ strokes: [InkStroke], for pageIndex: Int) {
            if strokes.isEmpty {
                parent.pageInkStrokes.removeValue(forKey: pageIndex)
            } else {
                parent.pageInkStrokes[pageIndex] = strokes
            }
            lastStrokeSignature = strokeSignature(for: parent.pageInkStrokes)
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

        // MARK: - Screen-space ink rendering

        func rebuildRenderedInk() {
            guard let hostPDFView, let inkRenderView,
                  let document = hostPDFView.document else { return }
            let visiblePages = hostPDFView.visiblePages
            let pages = visiblePages.isEmpty ? hostPDFView.currentPage.map { [$0] } ?? [] : visiblePages

            var rendered: [RenderedPDFInkStroke] = []
            for page in pages {
                let pageIndex = document.index(for: page)
                guard pageIndex >= 0 else { continue }
                let strokes = parent.pageInkStrokes[pageIndex] ?? []
                let eraserPreviewIDs = eraserPreviewStrokeIDs(pageIndex: pageIndex, strokes: strokes)
                rendered.append(contentsOf: renderStrokes(
                    strokes,
                    page: page,
                    pdfView: hostPDFView,
                    cachesOutlines: true,
                    eraserPreviewIDs: eraserPreviewIDs
                ))

                if pageIndex == activePageIndex,
                   let activeStroke,
                   activeStroke.tool != .eraser {
                    if let renderedStroke = makeRenderedStroke(
                        activeStroke,
                        page: page,
                        pdfView: hostPDFView,
                        cachesOutline: false,
                        isComplete: false
                    ) {
                        rendered.append(renderedStroke)
                    }
                }
            }
            inkRenderView.strokes = rendered
        }

        private func renderStrokes(_ strokes: [InkStroke],
                                   page: PDFPage,
                                   pdfView: PDFView,
                                   cachesOutlines: Bool,
                                   eraserPreviewIDs: Set<UUID>) -> [RenderedPDFInkStroke] {
            return strokes.compactMap { stroke in
                makeRenderedStroke(
                    stroke,
                    page: page,
                    pdfView: pdfView,
                    cachesOutline: cachesOutlines,
                    isComplete: true,
                    opacity: eraserPreviewIDs.contains(stroke.id) ? 0.28 : 1
                )
            }
        }

        private func makeRenderedStroke(_ stroke: InkStroke,
                                        page: PDFPage,
                                        pdfView: PDFView,
                                        cachesOutline: Bool,
                                        isComplete: Bool,
                                        opacity: CGFloat = 1) -> RenderedPDFInkStroke? {
            guard stroke.tool != .eraser else { return nil }
            guard let pagePath = pageSpaceOutlinePath(
                for: stroke,
                cachesOutline: cachesOutline,
                isComplete: isComplete
            ) else {
                return nil
            }
            var transform = pageSpaceToViewTransform(page: page, pdfView: pdfView)
            guard let viewPath = pagePath.copy(using: &transform) else { return nil }
            let isMarker = stroke.tool == .marker || stroke.tool == .highlighter
            return RenderedPDFInkStroke(
                path: viewPath,
                color: stroke.color.uiColor,
                blendMode: isMarker ? .multiply : .normal,
                opacity: opacity
            )
        }

        private func eraserPreviewStrokeIDs(pageIndex: Int, strokes: [InkStroke]) -> Set<UUID> {
            guard pageIndex == activePageIndex,
                  let activeStroke,
                  activeStroke.tool == .eraser,
                  !activeStroke.points.isEmpty else {
                return []
            }
            let radius = max(activeStroke.baseWidth * 0.5, 3)
            return Set(strokes.compactMap { stroke in
                self.stroke(stroke, intersectsEraser: activeStroke, radius: radius) ? stroke.id : nil
            })
        }

        private func pageSpaceOutlinePath(for stroke: InkStroke,
                                          cachesOutline: Bool,
                                          isComplete: Bool) -> CGPath? {
            if cachesOutline {
                let key = PDFInkOutlineCacheKey(stroke: stroke)
                if let cached = outlineCache[key] {
                    return cached
                }
                guard let outline = InkStrokeGeometry.outline(for: stroke, isComplete: isComplete) else { return nil }
                let path = outline.makeClosedPath()
                outlineCache[key] = path
                return path
            }

            guard let outline = InkStrokeGeometry.outline(for: stroke, isComplete: isComplete) else { return nil }
            return outline.makeClosedPath()
        }

        private func pageSpaceToViewTransform(page: PDFPage, pdfView: PDFView) -> CGAffineTransform {
            let pageBounds = page.bounds(for: .mediaBox)
            let origin = pdfView.convert(CGPoint(x: pageBounds.minX, y: pageBounds.maxY), from: page)
            let xUnit = pdfView.convert(CGPoint(x: pageBounds.minX + 1, y: pageBounds.maxY), from: page)
            let yUnit = pdfView.convert(CGPoint(x: pageBounds.minX, y: pageBounds.maxY - 1), from: page)
            return CGAffineTransform(
                a: xUnit.x - origin.x,
                b: xUnit.y - origin.y,
                c: yUnit.x - origin.x,
                d: yUnit.y - origin.y,
                tx: origin.x,
                ty: origin.y
            )
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
            guard let hostPDFView, let inkRenderView else { return }
            let key = viewportKey(pdfView: hostPDFView, renderView: inkRenderView)
            if key != lastViewportKey {
                lastViewportKey = key
                rebuildRenderedInk()
                refreshHoverIndicator()
            }
        }

        private func viewportKey(pdfView: PDFView, renderView: UIView) -> String {
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
                "\(Int(renderView.bounds.width))x\(Int(renderView.bounds.height))",
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
            guard activeStroke == nil else {
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
            guard activeStroke == nil else {
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

private struct RenderedPDFInkStroke {
    var path: CGPath
    var color: UIColor
    var blendMode: CGBlendMode
    var opacity: CGFloat
}

private final class PDFInkRenderView: UIView {
    var strokes: [RenderedPDFInkStroke] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
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
            context.saveGState()
            context.setBlendMode(stroke.blendMode)
            context.setAlpha(stroke.opacity)
            context.setFillColor(stroke.color.cgColor)
            context.addPath(stroke.path)
            context.fillPath()
            context.restoreGState()
        }
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

private extension InkColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red),
                green: CGFloat(green),
                blue: CGFloat(blue),
                alpha: CGFloat(alpha))
    }
}
