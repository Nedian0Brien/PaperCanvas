import UIKit

enum PDFPencilInputPhase {
    case began
    case moved
    case ended
    case cancelled
}

/// Gesture recognizer for PDF ink input.
///
/// It listens only to Apple Pencil touches on device, so finger gestures stay
/// owned by PDFKit's internal scroll view. On the simulator it accepts direct
/// touches so the input path can still be exercised without hardware.
final class PDFPencilInputGestureRecognizer: UIGestureRecognizer {
    var onTouches: ((PDFPencilInputPhase, [UITouch], UIEvent?) -> Void)?

    private weak var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = true
        #if !targetEnvironment(simulator)
        allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        #endif
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func reset() {
        trackedTouch = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil,
              let touch = touches.first(where: isAcceptedTouch) else {
            state = .failed
            return
        }
        trackedTouch = touch
        state = .began
        onTouches?(.began, coalescedTouches(for: touch, in: event), event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch,
              touches.contains(touch) else { return }
        state = .changed
        onTouches?(.moved, coalescedTouches(for: touch, in: event), event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch,
              touches.contains(touch) else { return }
        onTouches?(.ended, coalescedTouches(for: touch, in: event), event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch,
              touches.contains(touch) else { return }
        onTouches?(.cancelled, [touch], event)
        state = .cancelled
    }

    private func coalescedTouches(for touch: UITouch, in event: UIEvent) -> [UITouch] {
        event.coalescedTouches(for: touch) ?? [touch]
    }

    private func isAcceptedTouch(_ touch: UITouch) -> Bool {
        #if targetEnvironment(simulator)
        return touch.type == .direct || touch.type == .pencil
        #else
        return touch.type == .pencil
        #endif
    }
}
