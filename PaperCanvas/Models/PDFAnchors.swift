import Foundation
import SwiftData
import CoreGraphics

enum PDFAnchorKind: String, Codable {
    case text
    case region
}

@Model
final class PDFTextHighlight {
    @Attribute(.unique) var id: UUID
    var pageIndex: Int
    var quadPointsData: Data
    var colorHex: String
    var createdAt: Date
    var document: PaperDocument?

    init(pageIndex: Int,
         quadPoints: [CGRect],
         colorHex: String) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.quadPointsData = PDFTextHighlight.encode(quadPoints)
        self.colorHex = colorHex
        self.createdAt = .now
    }

    var quadPoints: [CGRect] {
        get { PDFTextHighlight.decode(quadPointsData) }
        set { quadPointsData = PDFTextHighlight.encode(newValue) }
    }

    var boundingPageRect: CGRect {
        let rects = quadPoints
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private static func encode(_ rects: [CGRect]) -> Data {
        let values = rects.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
        return (try? JSONEncoder().encode(values)) ?? Data()
    }

    private static func decode(_ data: Data) -> [CGRect] {
        guard let values = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return values.compactMap { arr in
            guard arr.count == 4 else { return nil }
            return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
    }
}

@Model
final class PDFRegionMark {
    @Attribute(.unique) var id: UUID
    var pageIndex: Int
    var rectX: Double
    var rectY: Double
    var rectW: Double
    var rectH: Double
    var colorHex: String
    var createdAt: Date
    var document: PaperDocument?

    init(pageIndex: Int,
         rect: CGRect,
         colorHex: String) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.rectX = Double(rect.origin.x)
        self.rectY = Double(rect.origin.y)
        self.rectW = Double(rect.size.width)
        self.rectH = Double(rect.size.height)
        self.colorHex = colorHex
        self.createdAt = .now
    }

    var pageRect: CGRect {
        get { CGRect(x: rectX, y: rectY, width: rectW, height: rectH) }
        set {
            rectX = Double(newValue.origin.x)
            rectY = Double(newValue.origin.y)
            rectW = Double(newValue.size.width)
            rectH = Double(newValue.size.height)
        }
    }
}

enum AnchorColor {
    static func hex(from color: CGColor) -> String {
        let components = color.components ?? [0, 0, 0, 1]
        let r = Int((components.indices.contains(0) ? components[0] : 0) * 255)
        let g = Int((components.indices.contains(1) ? components[1] : 0) * 255)
        let b = Int((components.indices.contains(2) ? components[2] : 0) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func cgColor(from hex: String) -> CGColor {
        var trimmed = hex
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else {
            return CGColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1)
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
