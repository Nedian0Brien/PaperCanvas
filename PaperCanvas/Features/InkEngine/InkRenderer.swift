import Foundation
import Metal
import MetalKit
import simd

struct InkVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

struct InkUniforms {
    var cameraMatrix: simd_float4x4
}

@MainActor
final class InkRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0
    private var dirty: Bool = true

    private(set) var strokes: [InkStroke] = []
    private(set) var inProgressStroke: InkStroke?

    var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    var viewportSize: SIMD2<Float> = .init(1, 1)

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        super.init()
    }

    func configure(view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        buildPipeline(view: view)
    }

    func setStrokes(_ s: [InkStroke]) {
        strokes = s
        dirty = true
    }

    func appendStroke(_ s: InkStroke) {
        strokes.append(s)
        dirty = true
    }

    func setInProgress(_ s: InkStroke?) {
        inProgressStroke = s
        dirty = true
    }

    func removeStroke(id: UUID) {
        strokes.removeAll { $0.id == id }
        dirty = true
    }

    func removeAll() {
        strokes.removeAll()
        dirty = true
    }

    // MARK: - Pipeline

    private func buildPipeline(view: MTKView) {
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
            print("InkRenderer: failed to load default library")
            return
        }
        guard let vfunc = library.makeFunction(name: "ink_vertex"),
              let ffunc = library.makeFunction(name: "ink_fragment") else {
            print("InkRenderer: failed to find shader functions")
            return
        }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float4
        vd.attributes[2].offset = MemoryLayout<SIMD2<Float>>.stride * 2
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<InkVertex>.stride

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfunc
        pd.fragmentFunction = ffunc
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            print("InkRenderer: pipeline state creation failed: \(error)")
        }
    }

    // MARK: - Vertex generation

    private func rebuildVertexBuffer() {
        var verts: [InkVertex] = []
        verts.reserveCapacity(strokes.reduce(0) { $0 + $1.points.count } * 6)

        for stroke in strokes {
            appendVertices(for: stroke, into: &verts)
        }
        if let p = inProgressStroke {
            appendVertices(for: p, into: &verts)
        }

        vertexCount = verts.count
        if verts.isEmpty {
            vertexBuffer = nil
            return
        }
        let byteLength = MemoryLayout<InkVertex>.stride * verts.count
        if let existing = vertexBuffer, existing.length >= byteLength {
            memcpy(existing.contents(), verts, byteLength)
        } else {
            vertexBuffer = device.makeBuffer(bytes: verts, length: byteLength, options: .storageModeShared)
        }
    }

    private func appendVertices(for stroke: InkStroke, into verts: inout [InkVertex]) {
        guard !stroke.points.isEmpty else { return }
        let color = stroke.color.simd
        let isHighlighter = stroke.tool == .highlighter || stroke.tool == .marker
        let alphaScale: Float = isHighlighter ? 0.45 : 1.0
        let baseStride = max(Float(stroke.baseWidth) * 0.12, 0.3)

        var lastEmitted: SIMD2<Float>? = nil

        for p in stroke.points {
            let pos = SIMD2<Float>(Float(p.location.x), Float(p.location.y))
            if let last = lastEmitted {
                let d = simd_distance(last, pos)
                if d < baseStride { continue }
            }
            lastEmitted = pos

            let forceFactor: Float = 0.55 + Float(p.force) * 0.85
            let stampSize = max(Float(stroke.baseWidth) * forceFactor, 1.0)
            let half = stampSize * 0.5

            let stampColor = SIMD4<Float>(color.x, color.y, color.z, color.w * alphaScale)
            let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
                (.init(-1, -1), .init(-half, -half)),
                (.init( 1, -1), .init( half, -half)),
                (.init( 1,  1), .init( half,  half)),
                (.init(-1, -1), .init(-half, -half)),
                (.init( 1,  1), .init( half,  half)),
                (.init(-1,  1), .init(-half,  half)),
            ]
            for (uv, offset) in corners {
                verts.append(InkVertex(position: pos + offset, uv: uv, color: stampColor))
            }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = .init(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        if dirty {
            rebuildVertexBuffer()
            dirty = false
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        if let buffer = vertexBuffer, vertexCount > 0 {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var uniforms = InkUniforms(cameraMatrix: cameraTransform)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<InkUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Camera

enum InkCamera {
    /// Build a 4x4 matrix that maps world coordinates to clip space `[-1, 1]`.
    /// `viewport` is in points, `panInWorld` is the world-space top-left corner of the visible area,
    /// `zoom` is the world-to-view scale (1 = no zoom).
    static func matrix(viewport: SIMD2<Float>, panInWorld: SIMD2<Float>, zoom: Float) -> simd_float4x4 {
        let sx = 2.0 * zoom / viewport.x
        let sy = -2.0 * zoom / viewport.y
        let tx = -1.0 - sx * panInWorld.x
        let ty =  1.0 - sy * panInWorld.y
        return simd_float4x4(rows: [
            .init(sx, 0,   0, tx),
            .init(0,  sy,  0, ty),
            .init(0,  0,   1, 0),
            .init(0,  0,   0, 1),
        ])
    }
}
