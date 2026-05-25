import UIKit

enum CanvasBackground: String, Codable, CaseIterable, Identifiable {
    case plain
    case dots
    case grid
    case lines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "없음"
        case .dots:  return "도트"
        case .grid:  return "격자"
        case .lines: return "줄"
        }
    }

    var systemImage: String {
        switch self {
        case .plain: return "rectangle"
        case .dots:  return "circle.grid.2x2"
        case .grid:  return "square.grid.3x3"
        case .lines: return "line.3.horizontal"
        }
    }

    static let tileSpacing: CGFloat = 28

    func makePatternImage(for traits: UITraitCollection? = nil) -> UIImage? {
        guard self != .plain else { return nil }
        let spacing = CanvasBackground.tileSpacing
        let size = CGSize(width: spacing, height: spacing)

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let fill = traits.map { UIColor.systemBackground.resolvedColor(with: $0) } ?? .systemBackground
        let ink = traits.map { UIColor.label.resolvedColor(with: $0) } ?? .label

        return renderer.image { ctx in
            fill.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            switch self {
            case .plain:
                return
            case .dots:
                ink.withAlphaComponent(0.30).setFill()
                let r: CGFloat = 1.0
                ctx.cgContext.fillEllipse(in: CGRect(
                    x: spacing / 2 - r,
                    y: spacing / 2 - r,
                    width: r * 2,
                    height: r * 2))
            case .grid:
                ink.withAlphaComponent(0.16).setStroke()
                ctx.cgContext.setLineWidth(0.5)
                ctx.cgContext.move(to: CGPoint(x: 0, y: 0))
                ctx.cgContext.addLine(to: CGPoint(x: spacing, y: 0))
                ctx.cgContext.move(to: CGPoint(x: 0, y: 0))
                ctx.cgContext.addLine(to: CGPoint(x: 0, y: spacing))
                ctx.cgContext.strokePath()
            case .lines:
                ink.withAlphaComponent(0.16).setStroke()
                ctx.cgContext.setLineWidth(0.5)
                ctx.cgContext.move(to: CGPoint(x: 0, y: 0))
                ctx.cgContext.addLine(to: CGPoint(x: spacing, y: 0))
                ctx.cgContext.strokePath()
            }
        }
    }

    // Wrapped in `UIColor(dynamicProvider:)` so the pattern image is
    // re-rasterized whenever the trait collection (e.g. light/dark mode)
    // changes — a `UIColor(patternImage:)` built once would otherwise stay
    // frozen at the appearance it was generated for.
    func uiBackgroundColor() -> UIColor {
        guard self != .plain else { return .systemBackground }
        return UIColor { [self] traits in
            guard let image = self.makePatternImage(for: traits) else {
                return .systemBackground
            }
            return UIColor(patternImage: image)
        }
    }
}

final class CanvasBackgroundView: UIView {
    var backgroundType: CanvasBackground = .plain {
        didSet {
            guard oldValue != backgroundType else { return }
            apply()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func apply() {
        backgroundColor = backgroundType.uiBackgroundColor()
    }
}

