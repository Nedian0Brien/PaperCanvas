import MetalKit
import UIKit

@MainActor
final class InkMetalView: MTKView {
    let inkRenderer: InkRenderer

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let mtlDevice = device ?? MTLCreateSystemDefaultDevice()
        guard let dev = mtlDevice, let renderer = InkRenderer(device: dev) else {
            fatalError("InkMetalView: Metal device unavailable")
        }
        self.inkRenderer = renderer
        super.init(frame: frameRect, device: dev)

        renderer.configure(view: self)
        delegate = renderer
        enableSetNeedsDisplay = true
        isPaused = true
        autoResizeDrawable = true
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let scale = traitCollection.displayScale
        if scale > 0 {
            contentScaleFactor = scale
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let s = window?.traitCollection.displayScale, s > 0 {
            contentScaleFactor = s
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }
}
