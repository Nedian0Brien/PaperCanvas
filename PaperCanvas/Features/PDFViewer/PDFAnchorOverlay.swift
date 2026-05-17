import UIKit
import PDFKit

/// Identifies an anchor (text highlight or region mark) so PDFAnchorOverlay
/// can report taps and drags back to its delegate without exposing model types.
struct AnchorRef: Equatable, Identifiable {
    let kind: PDFAnchorKind
    let id: UUID
    let pageIndex: Int
    let pageRect: CGRect          // page-space bounding rect (mediaBox coords)
    let text: String?             // for text highlights
    let colorHex: String
}

@MainActor
protocol PDFAnchorOverlayDelegate: AnyObject {
    func anchorOverlay(_ overlay: PDFAnchorOverlay,
                       didTap anchor: AnchorRef)
    func anchorOverlay(_ overlay: PDFAnchorOverlay,
                       dragItemsFor anchor: AnchorRef) -> [UIDragItem]
}

@MainActor
final class PDFAnchorOverlay: UIView {
    weak var delegate: PDFAnchorOverlayDelegate?
    weak var pdfView: PDFView?

    private var anchorViews: [UUID: AnchorBoxContainerView] = [:]
    private var anchors: [UUID: AnchorRef] = [:]

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        backgroundColor = .clear
        isOpaque = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // We don't intercept taps for the empty area — only individual anchor
        // boxes should receive touches.
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// True when there is no anchor at the given point — letting parent
    /// gestures (text selection, scroll, marker, etc.) pass through.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for child in anchorViews.values where !child.isHidden {
            let inChild = convert(point, to: child)
            if child.point(inside: inChild, with: event) { return true }
        }
        return false
    }

    func sync(textHighlights: [PDFTextHighlight],
              regionMarks: [PDFRegionMark],
              in pdfView: PDFView) {
        var liveIDs = Set<UUID>()

        for highlight in textHighlights {
            liveIDs.insert(highlight.id)
            let anchor = AnchorRef(
                kind: .text,
                id: highlight.id,
                pageIndex: highlight.pageIndex,
                pageRect: highlight.boundingPageRect,
                text: nil,
                colorHex: highlight.colorHex
            )
            anchors[highlight.id] = anchor
            let quads = highlight.quadPoints
            installOrUpdate(anchor: anchor, quadPoints: quads, in: pdfView)
        }
        for region in regionMarks {
            liveIDs.insert(region.id)
            let anchor = AnchorRef(
                kind: .region,
                id: region.id,
                pageIndex: region.pageIndex,
                pageRect: region.pageRect,
                text: nil,
                colorHex: region.colorHex
            )
            anchors[region.id] = anchor
            installOrUpdate(anchor: anchor, quadPoints: [region.pageRect], in: pdfView)
        }

        for (id, view) in anchorViews where !liveIDs.contains(id) {
            view.removeFromSuperview()
            anchorViews.removeValue(forKey: id)
            anchors.removeValue(forKey: id)
        }
    }

    func relayoutForViewportChange() {
        guard let pdfView else { return }
        for (id, container) in anchorViews {
            guard let anchor = anchors[id] else { continue }
            applyLayout(for: container, anchor: anchor, in: pdfView)
        }
    }

    private func installOrUpdate(anchor: AnchorRef,
                                 quadPoints: [CGRect],
                                 in pdfView: PDFView) {
        let container: AnchorBoxContainerView
        if let existing = anchorViews[anchor.id] {
            container = existing
        } else {
            container = AnchorBoxContainerView(anchor: anchor)
            container.onTap = { [weak self] anchor in
                guard let self else { return }
                self.delegate?.anchorOverlay(self, didTap: anchor)
            }
            container.dragItemsProvider = { [weak self] anchor -> [UIDragItem] in
                guard let self else { return [] }
                return self.delegate?.anchorOverlay(self, dragItemsFor: anchor) ?? []
            }
            addSubview(container)
            anchorViews[anchor.id] = container
        }
        container.anchor = anchor
        container.update(quadPoints: quadPoints)
        applyLayout(for: container, anchor: anchor, in: pdfView)
    }

    private func applyLayout(for container: AnchorBoxContainerView,
                             anchor: AnchorRef,
                             in pdfView: PDFView) {
        guard let document = pdfView.document,
              anchor.pageIndex >= 0,
              anchor.pageIndex < document.pageCount,
              let page = document.page(at: anchor.pageIndex) else {
            container.isHidden = true
            return
        }
        let viewQuads = container.quadPoints.map { pageRect -> CGRect in
            let topLeft = pdfView.convert(CGPoint(x: pageRect.minX, y: pageRect.maxY), from: page)
            let bottomRight = pdfView.convert(CGPoint(x: pageRect.maxX, y: pageRect.minY), from: page)
            let local = self.convert(topLeft, from: pdfView)
            let local2 = self.convert(bottomRight, from: pdfView)
            return CGRect(x: min(local.x, local2.x),
                          y: min(local.y, local2.y),
                          width: abs(local2.x - local.x),
                          height: abs(local2.y - local.y)).standardized
        }
        guard let union = viewQuads.dropFirst().reduce(viewQuads.first, { acc, r in
            acc.map { $0.union(r) } ?? r
        }) else {
            container.isHidden = true
            return
        }
        container.isHidden = false
        container.frame = union
        let localQuads = viewQuads.map { rect in
            CGRect(x: rect.minX - union.minX,
                   y: rect.minY - union.minY,
                   width: rect.width,
                   height: rect.height)
        }
        container.applyLocalQuads(localQuads)
    }
}

@MainActor
private final class AnchorBoxContainerView: UIView,
                                            UIDragInteractionDelegate,
                                            UIGestureRecognizerDelegate {
    var anchor: AnchorRef
    private(set) var quadPoints: [CGRect] = []
    private var localQuads: [CGRect] = []

    var onTap: ((AnchorRef) -> Void)?
    var dragItemsProvider: ((AnchorRef) -> [UIDragItem])?

    private static let fingerOnly: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]

    init(anchor: AnchorRef) {
        self.anchor = anchor
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw

        // Drag from anchor is finger-driven (long-press). Apple Pencil touches
        // continue through to PDFKit's pencil input pipeline so the marker tool
        // can keep highlighting / drawing across an existing anchor.
        let dragInteraction = UIDragInteraction(delegate: self)
        dragInteraction.isEnabled = true
        addInteraction(dragInteraction)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = AnchorBoxContainerView.fingerOnly
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func update(quadPoints: [CGRect]) {
        self.quadPoints = quadPoints
    }

    func applyLocalQuads(_ rects: [CGRect]) {
        localQuads = rects
        setNeedsDisplay()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only register hits inside one of the quad rects so users can tap
        // text between highlighted lines without accidentally hitting the
        // overlay's bounding box.
        for rect in localQuads where rect.insetBy(dx: -2, dy: -2).contains(point) {
            return true
        }
        return false
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let color = AnchorColor.cgColor(from: anchor.colorHex)
        switch anchor.kind {
        case .text:
            ctx.setFillColor(color.copy(alpha: 0.35) ?? color)
            for r in localQuads {
                ctx.fill(r)
            }
        case .region:
            ctx.setFillColor(color.copy(alpha: 0.10) ?? color)
            ctx.setStrokeColor(color.copy(alpha: 0.85) ?? color)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            for r in localQuads {
                ctx.addRect(r)
            }
            ctx.drawPath(using: .fillStroke)
        }
    }

    @objc private func handleTap() {
        onTap?(anchor)
    }

    // MARK: UIDragInteractionDelegate

    nonisolated func dragInteraction(_ interaction: UIDragInteraction,
                                     itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        MainActor.assumeIsolated {
            dragItemsProvider?(anchor) ?? []
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
