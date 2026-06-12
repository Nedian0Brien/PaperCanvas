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

struct InkToolSettings: Codable, Equatable, Sendable {
    var pressureSensitivity: CGFloat
    var textureStrength: CGFloat

    static func defaultSettings(for tool: InkTool) -> InkToolSettings {
        switch tool {
        case .pencil:
            return InkToolSettings(pressureSensitivity: 1.0, textureStrength: 1.0)
        case .pen, .gelPen, .fountainPen:
            return InkToolSettings(pressureSensitivity: 1.0, textureStrength: 0.0)
        case .brushPen:
            return InkToolSettings(pressureSensitivity: 1.15, textureStrength: 0.0)
        case .marker, .highlighter:
            return InkToolSettings(pressureSensitivity: 0.65, textureStrength: 0.0)
        case .eraser:
            return InkToolSettings(pressureSensitivity: 0.0, textureStrength: 0.0)
        }
    }

    var clamped: InkToolSettings {
        InkToolSettings(
            pressureSensitivity: min(max(pressureSensitivity, 0), 2),
            textureStrength: min(max(textureStrength, 0), 1)
        )
    }
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
    var toolSettings: InkToolSettings
    var points: [InkPoint]
    var boundingBox: CGRect

    init(id: UUID = UUID(),
         tool: InkTool,
         color: InkColor,
         baseWidth: CGFloat,
         toolSettings: InkToolSettings? = nil,
         points: [InkPoint],
         boundingBox: CGRect? = nil) {
        self.id = id
        self.tool = tool
        self.color = color
        self.baseWidth = baseWidth
        self.toolSettings = (toolSettings ?? InkToolSettings.defaultSettings(for: tool)).clamped
        self.points = points
        self.boundingBox = boundingBox ?? Self.computeBoundingBox(
            for: points,
            baseWidth: baseWidth,
            toolSettings: self.toolSettings
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tool
        case color
        case baseWidth
        case toolSettings
        case points
        case boundingBox
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tool = try container.decode(InkTool.self, forKey: .tool)
        color = try container.decode(InkColor.self, forKey: .color)
        baseWidth = try container.decode(CGFloat.self, forKey: .baseWidth)
        toolSettings = try container
            .decodeIfPresent(InkToolSettings.self, forKey: .toolSettings)?
            .clamped ?? InkToolSettings.defaultSettings(for: tool)
        points = try container.decode([InkPoint].self, forKey: .points)
        boundingBox = try container.decodeIfPresent(CGRect.self, forKey: .boundingBox) ?? Self.computeBoundingBox(
            for: points,
            baseWidth: baseWidth,
            toolSettings: toolSettings
        )
    }

    static func computeBoundingBox(for points: [InkPoint], baseWidth: CGFloat) -> CGRect {
        computeBoundingBox(for: points, baseWidth: baseWidth, toolSettings: nil)
    }

    static func computeBoundingBox(for points: [InkPoint],
                                   baseWidth: CGFloat,
                                   toolSettings: InkToolSettings?) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.location.x, maxX = first.location.x
        var minY = first.location.y, maxY = first.location.y
        for p in points.dropFirst() {
            if p.location.x < minX { minX = p.location.x }
            if p.location.x > maxX { maxX = p.location.x }
            if p.location.y < minY { minY = p.location.y }
            if p.location.y > maxY { maxY = p.location.y }
        }
        let pressurePadding = 1 + (toolSettings?.clamped.pressureSensitivity ?? 1) * 0.45
        let texturePadding = 1 + (toolSettings?.clamped.textureStrength ?? 0) * 0.18
        let pad = max(baseWidth * pressurePadding * texturePadding, 4)
        return CGRect(x: minX - pad, y: minY - pad,
                      width: (maxX - minX) + pad * 2,
                      height: (maxY - minY) + pad * 2)
    }
}
