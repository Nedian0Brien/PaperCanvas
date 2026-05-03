import UIKit
import PDFKit

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

    override func draw(_ rect: CGRect) {
        let r = CGRect(x: min(startPoint.x, currentPoint.x),
                       y: min(startPoint.y, currentPoint.y),
                       width: abs(currentPoint.x - startPoint.x),
                       height: abs(currentPoint.y - startPoint.y))
        guard let ctx = UIGraphicsGetCurrentContext(),
              r.width > 0, r.height > 0 else { return }
        ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(r)
    }
}

final class RegionMarqueeController: NSObject, UIGestureRecognizerDelegate {
    weak var pdfView: PDFView?
    var onRegionCaptured: ((Int, CGRect, UIImage) -> Void)?

    private var overlay: MarqueeOverlay?

    init(pdfView: PDFView) {
        super.init()
        self.pdfView = pdfView
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        lp.minimumPressDuration = 0.5
        lp.delegate = self
        pdfView.addGestureRecognizer(lp)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pdfView,
              gesture is UILongPressGestureRecognizer else { return false }
        let viewLoc = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: viewLoc, nearest: false) else { return false }
        let pageLoc = pdfView.convert(viewLoc, to: page)
        return page.characterIndex(at: pageLoc) == -1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
        guard let pdfView else { return }
        let loc = gesture.location(in: pdfView)
        switch gesture.state {
        case .began:
            let o = MarqueeOverlay(frame: pdfView.bounds)
            o.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            o.startPoint = loc
            o.currentPoint = loc
            pdfView.addSubview(o)
            overlay = o
        case .changed:
            overlay?.currentPoint = loc
        case .ended, .cancelled, .failed:
            guard let o = overlay else { return }
            let viewRect = CGRect(x: min(o.startPoint.x, o.currentPoint.x),
                                  y: min(o.startPoint.y, o.currentPoint.y),
                                  width: abs(o.currentPoint.x - o.startPoint.x),
                                  height: abs(o.currentPoint.y - o.startPoint.y))
            o.removeFromSuperview()
            overlay = nil
            if gesture.state == .ended, viewRect.width > 24, viewRect.height > 24 {
                finalize(viewRect: viewRect)
            }
        default:
            break
        }
    }

    private func finalize(viewRect: CGRect) {
        guard let pdfView,
              let page = pdfView.page(for: CGPoint(x: viewRect.midX, y: viewRect.midY),
                                      nearest: true) else { return }
        let topLeftPage = pdfView.convert(CGPoint(x: viewRect.minX, y: viewRect.minY),
                                          to: page)
        let bottomRightPage = pdfView.convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY),
                                              to: page)
        let pageRect = CGRect(x: min(topLeftPage.x, bottomRightPage.x),
                              y: min(topLeftPage.y, bottomRightPage.y),
                              width: abs(bottomRightPage.x - topLeftPage.x),
                              height: abs(bottomRightPage.y - topLeftPage.y))
        guard pageRect.width > 1, pageRect.height > 1 else { return }
        let image = renderPDFRegion(page: page, rect: pageRect, scale: 2.0)
        let pageIndex = pdfView.document?.index(for: page) ?? 0
        onRegionCaptured?(pageIndex, pageRect, image)
    }

    private func renderPDFRegion(page: PDFPage, rect: CGRect, scale: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            let cg = ctx.cgContext
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            let pageBounds = page.bounds(for: .mediaBox)
            cg.translateBy(x: 0, y: pageBounds.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }
}
