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

