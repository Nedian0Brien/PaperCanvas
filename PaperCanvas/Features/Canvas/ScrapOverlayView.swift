import UIKit

final class ScrapOverlayView: UIView,
                              UIGestureRecognizerDelegate,
                              UIContextMenuInteractionDelegate {
    let scrapID: UUID
    let kind: ScrapKind

    var onTap: ((UUID) -> Void)?
    var onPositionChanged: ((UUID, CGPoint) -> Void)?
    var onSizeChanged: ((UUID, CGSize) -> Void)?
    var onEditRequested: ((UUID) -> Void)?
    var onDeleteRequested: ((UUID) -> Void)?

    private(set) var basePosition: CGPoint
    private(set) var baseSize: CGSize
    private(set) var currentZoom: CGFloat = 1.0

    private weak var label: UILabel?
    private weak var imageView: UIImageView?
    private var initialPanOrigin: CGPoint = .zero
    private var initialPinchSize: CGSize = .zero

    private static let fingerOnly: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    private static let minSize = CGSize(width: 60, height: 40)
    private static let maxSize = CGSize(width: 2000, height: 2000)

    init(scrap: ScrapItem) {
        self.scrapID = scrap.id
        self.kind = scrap.kind
        let pos = CGPoint(x: scrap.positionX, y: scrap.positionY)
        let size = CGSize(width: max(40, scrap.width), height: max(40, scrap.height))
        self.basePosition = pos
        self.baseSize = size
        super.init(frame: CGRect(origin: pos, size: size))

        backgroundColor = (scrap.kind == .text) ? .systemBackground : .clear
        layer.cornerRadius = 8
        layer.borderColor = UIColor.systemGray4.cgColor
        layer.borderWidth = 1
        layer.masksToBounds = true
        layer.allowsGroupOpacity = false

        switch scrap.kind {
        case .text:
            let l = UILabel()
            l.numberOfLines = 0
            l.text = scrap.text
            l.font = .preferredFont(forTextStyle: .body)
            l.textColor = .label
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
            NSLayoutConstraint.activate([
                l.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
            ])
            label = l
        case .image:
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.translatesAutoresizingMaskIntoConstraints = false
            if let data = scrap.imageData, let img = UIImage(data: data) {
                iv.image = img
            }
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.topAnchor.constraint(equalTo: topAnchor),
                iv.leadingAnchor.constraint(equalTo: leadingAnchor),
                iv.trailingAnchor.constraint(equalTo: trailingAnchor),
                iv.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            imageView = iv
        }

        installGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(from scrap: ScrapItem) {
        let newBase = CGPoint(x: scrap.positionX, y: scrap.positionY)
        let newSize = CGSize(width: max(40, scrap.width), height: max(40, scrap.height))
        if basePosition != newBase || baseSize != newSize {
            basePosition = newBase
            baseSize = newSize
            applyZoom(currentZoom)
        }
        switch kind {
        case .text:
            if label?.text != scrap.text { label?.text = scrap.text }
        case .image:
            if let data = scrap.imageData, let img = UIImage(data: data) {
                imageView?.image = img
            }
        }
    }

    func applyZoom(_ scale: CGFloat) {
        // PKCanvasView's zoom transform already scales subviews of its internal
        // content view, so we only track the zoom for pan-delta normalization
        // and keep the layout in world (un-zoomed) coordinates.
        currentZoom = scale
        transform = .identity
        bounds = CGRect(origin: .zero, size: baseSize)
        center = CGPoint(
            x: basePosition.x + baseSize.width / 2,
            y: basePosition.y + baseSize.height / 2
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
        onTap?(scrapID)
    }

    @objc private func handleEdit() {
        onEditRequested?(scrapID)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let superview else { return }
        // translation(in: superview) returns the delta in the superview's
        // pre-transform coords. Since PKCanvasView's zoom is applied to the
        // superview, this is already in world units — no /scale needed.
        let translation = g.translation(in: superview)
        let baseDelta = CGPoint(x: translation.x, y: translation.y)
        switch g.state {
        case .began:
            initialPanOrigin = basePosition
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
            onPositionChanged?(scrapID, basePosition)
        case .cancelled, .failed:
            basePosition = initialPanOrigin
            applyZoom(currentZoom)
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            initialPinchSize = baseSize
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
            onSizeChanged?(scrapID, baseSize)
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
