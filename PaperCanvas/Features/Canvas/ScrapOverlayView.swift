import UIKit
import SwiftUI

final class ScrapOverlayView: UIView, UIGestureRecognizerDelegate {
    let scrapID: UUID
    let kind: ScrapKind
    let anchorKind: PDFAnchorKind?

    var onTap: ((UUID) -> Void)?
    var onPositionChanged: ((UUID, CGPoint) -> Void)?
    var onSizeChanged: ((UUID, CGSize) -> Void)?
    var onEditRequested: ((UUID) -> Void)?
    var onDeleteRequested: ((UUID) -> Void)?

    private(set) var basePosition: CGPoint
    private(set) var baseSize: CGSize
    private(set) var currentZoom: CGFloat = 1.0

    private var text: String?
    private var image: UIImage?
    private var documentTitle: String?
    private var pageIndex: Int

    var visualState: ScrapVisualState = .normal {
        didSet {
            guard oldValue != visualState else { return }
            if visualState != .selected {
                isContextMenuVisible = false
            }
            refreshContent()
            updateAffordanceVisibility()
        }
    }

    private var isContextMenuVisible: Bool = false {
        didSet {
            guard oldValue != isContextMenuVisible else { return }
            updateAffordanceVisibility()
        }
    }

    private let hostingController: UIHostingController<ScrapCardContent>
    private var contextMenuHost: UIHostingController<ScrapContextMenuContent>?
    private var contextMenuContainer: UIView?

    private var initialPanOrigin: CGPoint = .zero
    private var initialPinchSize: CGSize = .zero
    private var stateBeforeGesture: ScrapVisualState = .normal
    private var editingFlashWorkItem: DispatchWorkItem?

    private lazy var rightHandle = ScrapResizeHandleView(axis: .right)
    private lazy var bottomHandle = ScrapResizeHandleView(axis: .bottom)
    private lazy var cornerHandle = ScrapResizeHandleView(axis: .corner)
    private var handleViews: [ScrapResizeHandleView] { [rightHandle, bottomHandle, cornerHandle] }

    private var initialResizeSize: CGSize = .zero
    private var resizePan: UIPanGestureRecognizer?

    private static let fingerOnly: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    private static let minSize = CGSize(width: 120, height: 64)
    private static let maxSize = CGSize(width: 2000, height: 2000)
    private static let contextMenuGap: CGFloat = 12

    init(scrap: ScrapItem) {
        self.scrapID = scrap.id
        self.kind = scrap.kind
        self.anchorKind = scrap.anchorKind
        let pos = CGPoint(x: scrap.positionX, y: scrap.positionY)
        let size = CGSize(width: max(Self.minSize.width, scrap.width),
                          height: max(Self.minSize.height, scrap.height))
        self.basePosition = pos
        self.baseSize = size
        self.text = scrap.text
        self.image = scrap.imageData.flatMap { UIImage(data: $0) }
        self.documentTitle = scrap.document?.title
        self.pageIndex = scrap.sourcePageIndex

        let rootView = ScrapCardContent(
            kind: scrap.kind,
            anchorKind: scrap.anchorKind,
            text: scrap.text,
            image: self.image,
            documentTitle: self.documentTitle,
            pageIndex: scrap.sourcePageIndex,
            state: .normal,
            zoom: 1.0
        )
        self.hostingController = UIHostingController(rootView: rootView)

        super.init(frame: CGRect(origin: pos, size: size))

        backgroundColor = .clear
        layer.masksToBounds = false

        let hostView = hostingController.view!
        hostView.backgroundColor = .clear
        hostView.isUserInteractionEnabled = false
        hostView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: topAnchor),
            hostView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        installResizeHandles()
        installGestures()
        updateAffordanceVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The resize handles and context-menu bubble live as subviews positioned
    /// outside `bounds`. UIKit's default hit-testing won't route touches there
    /// because `point(inside:)` returns false for out-of-bounds points. Extend
    /// hit detection to include any visible affordance.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bounds.contains(point) { return true }
        for handle in handleViews where !handle.isHidden {
            if handle.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        }
        if let menu = contextMenuContainer, !menu.isHidden,
           menu.frame.contains(point) { return true }
        return false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachHostingControllerIfNeeded()
    }

    /// SwiftUI views hosted via `UIHostingController` need a real
    /// `UIViewController` parent for some Liquid Glass / environment-aware
    /// modifiers to materialize. Walk up the responder chain on first
    /// window attachment and adopt the nearest VC.
    private func attachHostingControllerIfNeeded() {
        guard window != nil else { return }
        let parentVC: UIViewController? = {
            var responder: UIResponder? = next
            while let r = responder {
                if let vc = r as? UIViewController { return vc }
                responder = r.next
            }
            return nil
        }()
        guard let vc = parentVC else { return }
        if hostingController.parent == nil {
            vc.addChild(hostingController)
            hostingController.didMove(toParent: vc)
        }
        if let menuHost = contextMenuHost, menuHost.parent == nil {
            vc.addChild(menuHost)
            menuHost.didMove(toParent: vc)
        }
    }

    func update(from scrap: ScrapItem) {
        let newBase = CGPoint(x: scrap.positionX, y: scrap.positionY)
        let newSize = CGSize(width: max(Self.minSize.width, scrap.width),
                             height: max(Self.minSize.height, scrap.height))
        if basePosition != newBase || baseSize != newSize {
            basePosition = newBase
            baseSize = newSize
            applyZoom(currentZoom)
        }

        var contentChanged = false
        if text != scrap.text {
            text = scrap.text
            contentChanged = true
        }
        let newImage = scrap.imageData.flatMap { UIImage(data: $0) }
        if image !== newImage {
            image = newImage
            contentChanged = true
        }
        let newTitle = scrap.document?.title
        if documentTitle != newTitle {
            documentTitle = newTitle
            contentChanged = true
        }
        if pageIndex != scrap.sourcePageIndex {
            pageIndex = scrap.sourcePageIndex
            contentChanged = true
        }
        if contentChanged {
            refreshContent()
        }
    }

    func applyZoom(_ scale: CGFloat) {
        // PKCanvasView does NOT auto-apply its zoom transform to subviews
        // added via `addSubview`. We have to scale and reposition manually so
        // scraps track strokes (which PencilKit zooms internally).
        currentZoom = scale
        bounds = CGRect(origin: .zero, size: baseSize)
        transform = CGAffineTransform(scaleX: scale, y: scale)
        center = CGPoint(
            x: (basePosition.x + baseSize.width / 2) * scale,
            y: (basePosition.y + baseSize.height / 2) * scale
        )
        layoutAffordances()
        refreshContent()
    }

    func clearContextMenu() {
        isContextMenuVisible = false
    }

    /// Briefly show an editing dashed border, then return to normal/selected.
    func flashEditingState() {
        editingFlashWorkItem?.cancel()
        let previous: ScrapVisualState = (visualState == .selected) ? .selected : .normal
        visualState = .editing
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.visualState == .editing {
                self.visualState = previous
            }
        }
        editingFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func refreshContent() {
        hostingController.rootView = ScrapCardContent(
            kind: kind,
            anchorKind: anchorKind,
            text: text,
            image: image,
            documentTitle: documentTitle,
            pageIndex: pageIndex,
            state: visualState,
            zoom: currentZoom
        )
    }

    private func installResizeHandles() {
        for handle in handleViews {
            handle.isHidden = true
            handle.onPanBegan = { [weak self] in self?.beginResize() }
            handle.onPanChanged = { [weak self] translation, axis in
                self?.continueResize(translation: translation, axis: axis)
            }
            handle.onPanEnded = { [weak self] cancelled in
                self?.finishResize(cancelled: cancelled)
            }
            addSubview(handle)
        }
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = ScrapOverlayView.fingerOnly
        tap.delegate = self
        addGestureRecognizer(tap)

        if kind == .text {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleEdit))
            doubleTap.allowedTouchTypes = ScrapOverlayView.fingerOnly
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = self
            addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = ScrapOverlayView.fingerOnly
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = ScrapOverlayView.fingerOnly
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    /// Don't let scrap-level tap/pan steal touches that landed on a resize
    /// handle subview — the handle owns those interactions.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let hit = touch.view else { return true }
        if hit is ScrapResizeHandleView { return false }
        var view: UIView? = hit
        while let v = view {
            if v is ScrapResizeHandleView { return false }
            if v === self { break }
            view = v.superview
        }
        return true
    }

    @objc private func handleTap() {
        switch visualState {
        case .normal, .editing:
            visualState = .selected
            isContextMenuVisible = false
        case .selected:
            isContextMenuVisible.toggle()
            if !isContextMenuVisible {
                visualState = .normal
            }
        case .dragging:
            break
        }
        onTap?(scrapID)
    }

    @objc private func handleEdit() {
        flashEditingState()
        onEditRequested?(scrapID)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let superview else { return }
        // basePosition lives in world (un-zoomed) coords, but the gesture
        // translation comes back in scroll-view (post-zoom) points, so divide
        // by the current zoom to keep finger and scrap in sync.
        let translation = g.translation(in: superview)
        let scale = max(currentZoom, 0.0001)
        let baseDelta = CGPoint(x: translation.x / scale, y: translation.y / scale)
        switch g.state {
        case .began:
            initialPanOrigin = basePosition
            stateBeforeGesture = visualState
            visualState = .dragging
            isContextMenuVisible = false
        case .changed:
            basePosition = CGPoint(
                x: initialPanOrigin.x + baseDelta.x,
                y: initialPanOrigin.y + baseDelta.y
            )
            applyZoom(currentZoom)
        case .ended:
            basePosition = CGPoint(
                x: initialPanOrigin.x + baseDelta.x,
                y: initialPanOrigin.y + baseDelta.y
            )
            applyZoom(currentZoom)
            visualState = .selected
            onPositionChanged?(scrapID, basePosition)
        case .cancelled, .failed:
            basePosition = initialPanOrigin
            applyZoom(currentZoom)
            visualState = stateBeforeGesture
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            initialPinchSize = baseSize
            stateBeforeGesture = visualState
            visualState = .dragging
            isContextMenuVisible = false
        case .changed:
            let scale = g.scale
            let newW = clamp(initialPinchSize.width * scale,
                             ScrapOverlayView.minSize.width,
                             ScrapOverlayView.maxSize.width)
            let newH = clamp(initialPinchSize.height * scale,
                             ScrapOverlayView.minSize.height,
                             ScrapOverlayView.maxSize.height)
            baseSize = CGSize(width: newW, height: newH)
            applyZoom(currentZoom)
        case .ended:
            visualState = .selected
            onSizeChanged?(scrapID, baseSize)
        case .cancelled, .failed:
            visualState = stateBeforeGesture
        default:
            break
        }
    }

    // MARK: - Resize handles

    private func beginResize() {
        initialResizeSize = baseSize
        stateBeforeGesture = visualState
        visualState = .dragging
        isContextMenuVisible = false
    }

    private func continueResize(translation: CGPoint,
                                axis: ScrapResizeHandleView.Axis) {
        let scale = max(currentZoom, 0.0001)
        let dx = translation.x / scale
        let dy = translation.y / scale
        var width = initialResizeSize.width
        var height = initialResizeSize.height
        switch axis {
        case .right:
            width = initialResizeSize.width + dx
        case .bottom:
            height = initialResizeSize.height + dy
        case .corner:
            width = initialResizeSize.width + dx
            height = initialResizeSize.height + dy
        }
        width = clamp(width, ScrapOverlayView.minSize.width, ScrapOverlayView.maxSize.width)
        height = clamp(height, ScrapOverlayView.minSize.height, ScrapOverlayView.maxSize.height)
        baseSize = CGSize(width: width, height: height)
        applyZoom(currentZoom)
    }

    private func finishResize(cancelled: Bool) {
        if cancelled {
            baseSize = initialResizeSize
            applyZoom(currentZoom)
            visualState = stateBeforeGesture
        } else {
            visualState = .selected
            onSizeChanged?(scrapID, baseSize)
        }
    }

    // MARK: - Affordance layout

    private func updateAffordanceVisibility() {
        let showHandles = (visualState == .selected || visualState == .dragging)
        for handle in handleViews {
            handle.isHidden = !showHandles
            handle.isUserInteractionEnabled = showHandles
        }
        layoutAffordances()
        updateContextMenuVisibility()
    }

    private func layoutAffordances() {
        let scale = max(currentZoom, 0.0001)
        let inverse = CGAffineTransform(scaleX: 1.0 / scale, y: 1.0 / scale)
        // The whole scrap view has a parent-applied scale, so inverse-scale the
        // handles to keep them at a constant on-screen size regardless of zoom.
        for handle in handleViews {
            handle.transform = inverse
        }
        rightHandle.center = CGPoint(x: bounds.maxX, y: bounds.midY)
        bottomHandle.center = CGPoint(x: bounds.midX, y: bounds.maxY)
        cornerHandle.center = CGPoint(x: bounds.maxX, y: bounds.maxY)

        if let container = contextMenuContainer {
            container.transform = inverse
            let menuSize = container.bounds.size
            let menuHalfHeight = menuSize.height / 2
            let gap = ScrapOverlayView.contextMenuGap
            // Position the menu above the scrap. Convert the desired
            // on-screen offset back into the scrap's unscaled coords by
            // dividing by `scale`.
            let yOffset = (menuHalfHeight + gap) / scale
            container.center = CGPoint(x: bounds.midX,
                                       y: bounds.minY - yOffset)
        }
    }

    // MARK: - Context menu bubble

    private func updateContextMenuVisibility() {
        let shouldShow = isContextMenuVisible && visualState == .selected
        if shouldShow {
            presentContextMenuIfNeeded()
        } else {
            dismissContextMenu()
        }
    }

    private func presentContextMenuIfNeeded() {
        if contextMenuContainer != nil {
            layoutAffordances()
            return
        }
        let content = ScrapContextMenuContent(
            allowsEdit: kind == .text,
            onEdit: { [weak self] in
                guard let self else { return }
                self.isContextMenuVisible = false
                self.flashEditingState()
                self.onEditRequested?(self.scrapID)
            },
            onDelete: { [weak self] in
                guard let self else { return }
                self.isContextMenuVisible = false
                self.onDeleteRequested?(self.scrapID)
            }
        )
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        let preferred = host.sizeThatFits(in: CGSize(width: 320, height: 320))
        let menuSize = CGSize(width: max(preferred.width, 64),
                              height: max(preferred.height, 40))
        host.view.frame = CGRect(origin: .zero, size: menuSize)
        addSubview(host.view)
        contextMenuHost = host
        contextMenuContainer = host.view
        attachHostingControllerIfNeeded()
        layoutAffordances()

        host.view.alpha = 0
        host.view.transform = host.view.transform.scaledBy(x: 0.85, y: 0.85)
        UIView.animate(withDuration: 0.18,
                       delay: 0,
                       usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.6,
                       options: [.allowUserInteraction]) {
            host.view.alpha = 1
            self.layoutAffordances()
        }
    }

    private func dismissContextMenu() {
        guard let host = contextMenuHost, let container = contextMenuContainer else { return }
        contextMenuHost = nil
        contextMenuContainer = nil
        UIView.animate(withDuration: 0.12,
                       delay: 0,
                       options: [.allowUserInteraction],
                       animations: {
            container.alpha = 0
            container.transform = container.transform.scaledBy(x: 0.85, y: 0.85)
        }, completion: { _ in
            host.willMove(toParent: nil)
            container.removeFromSuperview()
            host.removeFromParent()
        })
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(high, value))
    }
}

// MARK: - Resize handle view

final class ScrapResizeHandleView: UIView {
    enum Axis {
        case right, bottom, corner
    }

    let axis: Axis
    var onPanBegan: (() -> Void)?
    var onPanChanged: ((CGPoint, Axis) -> Void)?
    var onPanEnded: ((Bool) -> Void)?

    private static let hitSize: CGFloat = 52
    private let knob = UIView()

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: CGRect(x: 0, y: 0,
                                 width: Self.hitSize,
                                 height: Self.hitSize))
        backgroundColor = .clear
        isUserInteractionEnabled = true

        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.backgroundColor = UIColor.systemBackground
        knob.layer.borderColor = UIColor.tintColor.cgColor
        knob.layer.borderWidth = 1.5
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.18
        knob.layer.shadowRadius = 3
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(knob)

        let knobWidth: CGFloat
        let knobHeight: CGFloat
        let cornerRadius: CGFloat
        switch axis {
        case .right:
            knobWidth = 6
            knobHeight = 36
            cornerRadius = 3
        case .bottom:
            knobWidth = 36
            knobHeight = 6
            cornerRadius = 3
        case .corner:
            knobWidth = 16
            knobHeight = 16
            cornerRadius = 8
        }
        knob.layer.cornerRadius = cornerRadius
        NSLayoutConstraint.activate([
            knob.centerXAnchor.constraint(equalTo: centerXAnchor),
            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
            knob.widthAnchor.constraint(equalToConstant: knobWidth),
            knob.heightAnchor.constraint(equalToConstant: knobHeight)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Expand hit area beyond the visual knob so finger taps land easily.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -8).contains(point)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let superview = self.superview else { return }
        let translation = g.translation(in: superview)
        switch g.state {
        case .began:
            onPanBegan?()
        case .changed:
            onPanChanged?(translation, axis)
        case .ended:
            onPanChanged?(translation, axis)
            onPanEnded?(false)
        case .cancelled, .failed:
            onPanEnded?(true)
        default:
            break
        }
    }
}

// MARK: - Context menu content

private struct ScrapContextMenuContent: View {
    let allowsEdit: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if allowsEdit {
                ScrapContextMenuButton(systemImage: "square.and.pencil",
                                       label: "편집",
                                       accessibilityLabel: "편집",
                                       action: onEdit)
                Rectangle()
                    .fill(Color.Rule.hairline)
                    .frame(width: 0.5, height: 24)
            }
            ScrapContextMenuButton(systemImage: "trash",
                                   label: "삭제",
                                   accessibilityLabel: "삭제",
                                   tint: .red,
                                   action: onDelete)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .chromeGlassRect(cornerRadius: 22)
        .fixedSize()
    }
}

private struct ScrapContextMenuButton: View {
    let systemImage: String
    let label: String
    let accessibilityLabel: String
    var tint: Color = Color.Ink.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel(accessibilityLabel)
    }
}
