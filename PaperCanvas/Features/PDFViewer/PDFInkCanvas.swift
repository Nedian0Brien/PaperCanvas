import PencilKit
import UIKit

final class PencilOnlyCanvasView: PKCanvasView {
    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize != bounds.size {
            contentSize = bounds.size
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        #if targetEnvironment(simulator)
        return super.point(inside: point, with: event)
        #else
        guard let event = event else {
            return super.point(inside: point, with: event)
        }
        let touches = event.allTouches ?? []
        if touches.isEmpty {
            return super.point(inside: point, with: event)
        }
        if touches.contains(where: { $0.type == .pencil }) {
            return super.point(inside: point, with: event)
        }
        return false
        #endif
    }
}
