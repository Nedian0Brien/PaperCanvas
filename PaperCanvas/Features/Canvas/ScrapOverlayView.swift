import UIKit
import SwiftUI

final class ScrapOverlayView: UIView,
                              UIGestureRecognizerDelegate,
                              UIContextMenuInteractionDelegate {
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
            refreshContent()
        }
    }

    private let hostingController: UIHostingController<ScrapCardContent>
    private var initialPanOrigin: CGPoint = .zero
    private var initialPinchSize: CGSize = .zero
    private var stateBeforeGesture: ScrapVisualState = .normal
    private var editingFlashWorkItem: DispatchWorkItem?

    private static let fingerOnly: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    private static let minSize = CGSize(width: 120, height: 64)
    private static let maxSize = CGSize(width: 2000, height: 2000)

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

        installGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachHostingControllerIfNeeded()
    }

    /// SwiftUI views hosted via `UIHostingController` need a real
    /// `UIViewController` parent for some Liquid Glass / environment-aware
    /// modifiers to materialize. Walk up the responder chain on first
    /// window attachment and adopt the nearest VC.
    private func attachHostingControllerIfNeeded() {
        guard window != nil, hostingController.parent == nil else { return }
        var responder: UIResponder? = next
        while let r = responder {
            if let vc = r as? UIViewController {
                vc.addChild(hostingController)
                hostingController.didMove(toParent: vc)
                return
            }
            responder = r.next
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
        refreshContent()
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

        let menu = UIContextMenuInteraction(delegate: self)
        addInteraction(menu)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func handleTap() {
        visualState = (visualState == .selected) ? .normal : .selected
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

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(high, value))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = []
            if self.kind == .text {
                actions.append(UIAction(title: "편집",
                                        image: UIImage(systemName: "square.and.pencil")) { _ in
                    self.flashEditingState()
                    self.onEditRequested?(self.scrapID)
                })
            }
            let delete = UIAction(title: "삭제",
                                  image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { _ in
                self.onDeleteRequested?(self.scrapID)
            }
            actions.append(delete)
            return UIMenu(title: "", children: actions)
        }
    }
}
