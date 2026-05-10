import CoreGraphics
import Foundation
import PencilKit
import UIKit

enum PKDrawingConverter {
    static func toInkStrokes(_ drawing: PKDrawing) -> [InkStroke] {
        drawing.strokes.compactMap { convert($0) }
    }

    static func convert(_ stroke: PKStroke) -> InkStroke? {
        let tool = mapTool(stroke.ink.inkType)
        let color = makeColor(from: stroke.ink.color)
        let baseWidth = baseWidth(for: stroke.ink.inkType)

        var points: [InkPoint] = []
        points.reserveCapacity(stroke.path.count * 2)
        for p in stroke.path.interpolatedPoints(by: .distance(0.5)) {
            let transformed = p.location.applying(stroke.transform)
            let size = max(p.size.width, p.size.height)
            points.append(InkPoint(
                location: transformed,
                force: p.force,
                altitude: p.altitude,
                azimuth: p.azimuth,
                size: size,
                opacity: p.opacity,
                timeOffset: p.timeOffset
            ))
        }

        guard !points.isEmpty else { return nil }

        return InkStroke(
            tool: tool,
            color: color,
            baseWidth: baseWidth,
            points: points
        )
    }

    private static func mapTool(_ inkType: PKInk.InkType) -> InkTool {
        switch inkType {
        case .pen:         return .pen
        case .pencil:      return .pencil
        case .marker:      return .marker
        case .monoline:    return .pen
        case .fountainPen: return .pen
        case .watercolor:  return .marker
        case .crayon:      return .pencil
        case .reed:        return .pen
        @unknown default:  return .pen
        }
    }

    private static func makeColor(from ui: UIColor) -> InkColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return InkColor(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a))
    }

    private static func baseWidth(for inkType: PKInk.InkType) -> CGFloat {
        switch inkType {
        case .pen:         return 4
        case .pencil:      return 3
        case .marker:      return 18
        case .monoline:    return 4
        case .fountainPen: return 4
        case .watercolor:  return 22
        case .crayon:      return 8
        case .reed:        return 6
        @unknown default:  return 4
        }
    }
}
