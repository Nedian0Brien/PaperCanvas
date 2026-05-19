import UIKit

enum NotePageStyle: String, Codable, CaseIterable, Identifiable {
    case plain
    case lined
    case grid
    case dots
    case cornell

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain:   return "백지"
        case .lined:   return "줄노트"
        case .grid:    return "격자"
        case .dots:    return "도트"
        case .cornell: return "코넬"
        }
    }

    var systemImage: String {
        switch self {
        case .plain:   return "rectangle"
        case .lined:   return "line.3.horizontal"
        case .grid:    return "square.grid.3x3"
        case .dots:    return "circle.grid.2x2"
        case .cornell: return "rectangle.split.3x1"
        }
    }

    /// Spacing in points between rulings.
    var ruleSpacing: CGFloat {
        switch self {
        case .plain:   return 0
        case .lined:   return 32
        case .grid:    return 28
        case .dots:    return 28
        case .cornell: return 30
        }
    }

    /// US Letter @ ~150 dpi looks crisp on iPad; aspect 8.5:11.
    static let defaultPageSize = CGSize(width: 1024, height: 1325)

    /// Inset around the rule region inside the page.
    var pageInsets: UIEdgeInsets {
        switch self {
        case .cornell:
            return UIEdgeInsets(top: 96, left: 200, bottom: 120, right: 48)
        case .plain:
            return .zero
        default:
            return UIEdgeInsets(top: 72, left: 72, bottom: 72, right: 48)
        }
    }

    func drawBackground(in rect: CGRect, context: CGContext) {
        UIColor.systemBackground.setFill()
        context.fill(rect)
        drawRulings(in: rect, context: context)
    }

    private func drawRulings(in rect: CGRect, context: CGContext) {
        guard self != .plain else { return }
        let insets = pageInsets
        let ruleRect = rect.inset(by: insets)
        let lineColor = UIColor.label.withAlphaComponent(0.18)
        let strongColor = UIColor.systemRed.withAlphaComponent(0.35)

        context.saveGState()
        defer { context.restoreGState() }

        context.setLineWidth(0.5)

        switch self {
        case .plain:
            return
        case .lined:
            lineColor.setStroke()
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                context.move(to: CGPoint(x: ruleRect.minX, y: y))
                context.addLine(to: CGPoint(x: ruleRect.maxX, y: y))
                y += ruleSpacing
            }
            context.strokePath()
            // Left margin line in pale red.
            strongColor.setStroke()
            let marginX = ruleRect.minX - 32
            context.move(to: CGPoint(x: marginX, y: rect.minY + 24))
            context.addLine(to: CGPoint(x: marginX, y: rect.maxY - 24))
            context.strokePath()

        case .grid:
            lineColor.setStroke()
            var x = ruleRect.minX
            while x <= ruleRect.maxX {
                context.move(to: CGPoint(x: x, y: ruleRect.minY))
                context.addLine(to: CGPoint(x: x, y: ruleRect.maxY))
                x += ruleSpacing
            }
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                context.move(to: CGPoint(x: ruleRect.minX, y: y))
                context.addLine(to: CGPoint(x: ruleRect.maxX, y: y))
                y += ruleSpacing
            }
            context.strokePath()

        case .dots:
            UIColor.label.withAlphaComponent(0.30).setFill()
            let r: CGFloat = 1.0
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                var x = ruleRect.minX
                while x <= ruleRect.maxX {
                    context.fillEllipse(in: CGRect(x: x - r, y: y - r,
                                                   width: r * 2, height: r * 2))
                    x += ruleSpacing
                }
                y += ruleSpacing
            }

        case .cornell:
            // Three regions: cue column (left), note area (right), summary (bottom).
            let cueX = insets.left
            let summaryY = rect.maxY - insets.bottom
            // Note area lines
            lineColor.setStroke()
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                context.move(to: CGPoint(x: cueX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX - insets.right, y: y))
                y += ruleSpacing
            }
            context.strokePath()
            // Cue / summary dividers
            UIColor.label.withAlphaComponent(0.42).setStroke()
            context.setLineWidth(1.0)
            context.move(to: CGPoint(x: cueX, y: rect.minY + 32))
            context.addLine(to: CGPoint(x: cueX, y: summaryY))
            context.move(to: CGPoint(x: rect.minX + 24, y: summaryY))
            context.addLine(to: CGPoint(x: rect.maxX - 24, y: summaryY))
            context.strokePath()
        }
    }

    /// Renders a thumbnail of an empty page in this style, sized to fit the
    /// given longest edge.
    func renderThumbnail(maxDimension: CGFloat) -> UIImage {
        let pageSize = NotePageStyle.defaultPageSize
        let scale = maxDimension / max(pageSize.width, pageSize.height)
        let outSize = CGSize(width: pageSize.width * scale,
                             height: pageSize.height * scale)
        let renderer = UIGraphicsImageRenderer(size: outSize)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            drawBackground(in: CGRect(origin: .zero, size: pageSize), context: cg)
            cg.restoreGState()
        }
    }
}
