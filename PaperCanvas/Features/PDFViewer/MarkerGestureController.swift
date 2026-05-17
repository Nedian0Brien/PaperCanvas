import UIKit
import PDFKit

/// Owns the gestures that turn the marker tool into the "scrap" tool:
///   • short drag on empty space → ordinary ink stroke (handled elsewhere)
///   • short drag on text → text highlight (handled in PDFKitView pencil flow)
///   • 0.4 s hold + drag on empty space → region marquee (this controller)
@MainActor
final class MarkerGestureController: NSObject, UIGestureRecognizerDelegate {
    weak var pdfView: PDFView?
    weak var palette: PaletteState?

    /// Fires when a marquee selection finalizes. Caller is responsible for
    /// persisting the region mark and rendering its visual overlay.
    var onRegionCaptured: ((Int, CGRect, UIImage) -> Void)?

    private var overlay: MarqueeOverlay?

    init(pdfView: PDFView, palette: PaletteState) {
        super.init()
        self.pdfView = pdfView
        self.palette = palette
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        lp.minimumPressDuration = 0.4
        lp.delegate = self
        pdfView.addGestureRecognizer(lp)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let palette, palette.tool == .marker, palette.markerSubmode.regionEnabled else {
            return false
        }
        guard let pdfView,
              gesture is UILongPressGestureRecognizer else { return false }
        let viewLoc = gesture.location(in: pdfView)
        guard let page = pdfView.page(for: viewLoc, nearest: false) else { return false }
        let pageLoc = pdfView.convert(viewLoc, to: page)
        // Empty area only — text long-press is reserved for text selection.
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
        let image = MarkerGestureController.renderPDFRegion(page: page, rect: pageRect, scale: 2.0)
        let pageIndex = pdfView.document?.index(for: page) ?? 0
        onRegionCaptured?(pageIndex, pageRect, image)
    }

    /// Render a PDF page region to a UIImage at the given scale. Exposed so
    /// the anchor drag flow can re-capture an image from a stored
    /// PDFRegionMark when the user drags it to the canvas.
    static func renderPDFRegion(page: PDFPage, rect: CGRect, scale: CGFloat) -> UIImage {
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
