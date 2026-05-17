import UIKit
import PDFKit

/// Renders the in-progress text highlight rects above the PDF while the user
/// is dragging the marker across text. Decoupled from `pdfView.currentSelection`
/// so we always draw with the marker's color and can guarantee visibility even
/// when PDFKit's own selection chrome is suppressed by markup mode.
final class LiveHighlightOverlay: UIView {
    weak var pdfView: PDFView?
    var pageIndex: Int = 0
    /// Page-space rects (mediaBox coordinates) for each line of the active
    /// selection. Empty means nothing to draw.
    var pageRects: [CGRect] = [] { didSet { setNeedsDisplay() } }
    var color: UIColor = .systemYellow { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func clear() {
        pageRects = []
        isHidden = true
    }

    func update(pageIndex: Int, pageRects: [CGRect], color: UIColor) {
        self.pageIndex = pageIndex
        self.color = color
        self.pageRects = pageRects
        isHidden = pageRects.isEmpty
    }

    override func draw(_ rect: CGRect) {
        guard !pageRects.isEmpty,
              let pdfView,
              let document = pdfView.document,
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex),
              let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(color.withAlphaComponent(0.4).cgColor)
        for pageRect in pageRects {
            let topLeft = pdfView.convert(CGPoint(x: pageRect.minX, y: pageRect.maxY), from: page)
            let bottomRight = pdfView.convert(CGPoint(x: pageRect.maxX, y: pageRect.minY), from: page)
            let topLeftLocal = self.convert(topLeft, from: pdfView)
            let bottomRightLocal = self.convert(bottomRight, from: pdfView)
            let viewRect = CGRect(x: min(topLeftLocal.x, bottomRightLocal.x),
                                  y: min(topLeftLocal.y, bottomRightLocal.y),
                                  width: abs(bottomRightLocal.x - topLeftLocal.x),
                                  height: abs(bottomRightLocal.y - topLeftLocal.y))
            ctx.fill(viewRect)
        }
    }
}

final class MarqueeOverlay: UIView {
    var startPoint: CGPoint = .zero { didSet { setNeedsDisplay() } }
    var currentPoint: CGPoint = .zero { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Brief pulse the moment the long-press latches, so the user can tell
    /// they've entered region-selection mode even before they start dragging.
    func playEntryPulse() {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.18,
                       delay: 0,
                       usingSpringWithDamping: 0.7,
                       initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    override func draw(_ rect: CGRect) {
        let r = CGRect(x: min(startPoint.x, currentPoint.x),
                       y: min(startPoint.y, currentPoint.y),
                       width: abs(currentPoint.x - startPoint.x),
                       height: abs(currentPoint.y - startPoint.y))
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Anchor dot at the press point — visible from frame 1 so the user
        // sees "yes, region mode is armed" even before any drag.
        let dotRadius: CGFloat = 6
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        ctx.setShadow(offset: .zero, blur: 4, color: UIColor.systemBlue.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: startPoint.x - dotRadius,
                                   y: startPoint.y - dotRadius,
                                   width: dotRadius * 2,
                                   height: dotRadius * 2))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        guard r.width > 0, r.height > 0 else { return }
        ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(r)
    }
}
