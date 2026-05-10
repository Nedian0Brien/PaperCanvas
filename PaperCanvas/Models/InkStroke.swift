import CoreGraphics
import Foundation
import simd

enum InkTool: Int, Codable, Sendable {
    case pen = 0
    case pencil = 1
    case marker = 2
    case highlighter = 3
    case eraser = 4
    case gelPen = 5
    case fountainPen = 6
    case brushPen = 7
}

struct InkColor: Codable, Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    var simd: SIMD4<Float> { SIMD4(red, green, blue, alpha) }

    static let black = InkColor(red: 0, green: 0, blue: 0, alpha: 1)
}

struct InkPoint: Codable, Equatable, Sendable {
    var location: CGPoint
    var force: CGFloat
    var altitude: CGFloat
    var azimuth: CGFloat
    var size: CGFloat
    var opacity: CGFloat
    var timeOffset: TimeInterval
}

struct InkStroke: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var tool: InkTool
    var color: InkColor
    var baseWidth: CGFloat
    var points: [InkPoint]
    var boundingBox: CGRect

    init(id: UUID = UUID(),
         tool: InkTool,
         color: InkColor,
         baseWidth: CGFloat,
         points: [InkPoint],
         boundingBox: CGRect? = nil) {
        self.id = id
        self.tool = tool
        self.color = color
        self.baseWidth = baseWidth
        self.points = points
        self.boundingBox = boundingBox ?? Self.computeBoundingBox(for: points, baseWidth: baseWidth)
    }

    static func computeBoundingBox(for points: [InkPoint], baseWidth: CGFloat) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.location.x, maxX = first.location.x
        var minY = first.location.y, maxY = first.location.y
        for p in points.dropFirst() {
            if p.location.x < minX { minX = p.location.x }
            if p.location.x > maxX { maxX = p.location.x }
            if p.location.y < minY { minY = p.location.y }
            if p.location.y > maxY { maxY = p.location.y }
        }
        let pad = max(baseWidth, 4)
        return CGRect(x: minX - pad, y: minY - pad,
                      width: (maxX - minX) + pad * 2,
                      height: (maxY - minY) + pad * 2)
    }
}
