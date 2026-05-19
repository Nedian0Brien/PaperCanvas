import CoreGraphics
import Foundation
import PencilKit
import SwiftUI
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

    /// Build a PKStroke that approximates an InkStroke. Used for paste-into-canvas
    /// and lasso recolor operations on the PencilKit-backed surface.
    static func makePKStroke(from ink: InkStroke) -> PKStroke? {
        guard !ink.points.isEmpty else { return nil }
        let inkType = mapInkType(ink.tool)
        let pkInk = PKInk(inkType, color: ink.color.uiColor)
        let strokePoints = ink.points.map { point in
            PKStrokePoint(
                location: point.location,
                timeOffset: max(point.timeOffset, 0),
                size: CGSize(width: max(point.size, 1), height: max(point.size, 1)),
                opacity: max(0.05, min(point.opacity, 1)),
                force: point.force,
                azimuth: point.azimuth,
                altitude: point.altitude
            )
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        return PKStroke(ink: pkInk, path: path)
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

    private static func mapInkType(_ tool: InkTool) -> PKInk.InkType {
        switch tool {
        case .pen:         return .pen
        case .pencil:      return .pencil
        case .marker:      return .marker
        case .highlighter: return .marker
        case .eraser:      return .pen
        case .gelPen:      return .pen
        case .fountainPen: return .fountainPen
        case .brushPen:    return .marker
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

extension InkColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red),
                green: CGFloat(green),
                blue: CGFloat(blue),
                alpha: CGFloat(alpha))
    }

    init(_ color: Color, alpha: CGFloat = 1) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a * alpha))
    }
}

// MARK: - Lasso clipboard

/// Shared pasteboard for lasso selections. Carries a Codable payload of
/// `InkStroke` arrays so cut/copy/paste works across PDF pages and the
/// infinite canvas.
enum InkLassoClipboard {
    private static let pasteboardType = "com.papercanvas.ink-strokes"

    static func copy(_ strokes: [InkStroke]) {
        guard !strokes.isEmpty,
              let data = try? JSONEncoder().encode(strokes) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: pasteboardType)
    }

    static func paste() -> [InkStroke]? {
        guard let data = UIPasteboard.general.data(forPasteboardType: pasteboardType),
              let strokes = try? JSONDecoder().decode([InkStroke].self, from: data),
              !strokes.isEmpty else { return nil }
        return strokes.map { stroke in
            // Each paste gets fresh IDs so multiple pastes produce distinct strokes.
            InkStroke(
                id: UUID(),
                tool: stroke.tool,
                color: stroke.color,
                baseWidth: stroke.baseWidth,
                points: stroke.points,
                boundingBox: stroke.boundingBox
            )
        }
    }

    static var hasStrokes: Bool {
        UIPasteboard.general.contains(pasteboardTypes: [pasteboardType])
    }
}

// MARK: - Selection context menu

@MainActor
struct LassoMenuActions {
    var canPaste: Bool
    var onCut: () -> Void
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onRecolor: (Color) -> Void
    var onPickCustomColor: () -> Void
    var onDelete: () -> Void
}

@MainActor
final class LassoSelectionMenu: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
    static let shared = LassoSelectionMenu()

    private weak var hostView: UIView?
    private var sourceRect: CGRect = .zero
    private var actions: LassoMenuActions?
    private var pasteShortcutAction: (() -> Void)?
    private var interaction: UIEditMenuInteraction?

    func present(in view: UIView, sourceRect: CGRect, actions: LassoMenuActions) {
        dismiss()
        self.hostView = view
        self.sourceRect = sourceRect
        self.actions = actions
        self.pasteShortcutAction = nil

        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        self.interaction = interaction

        let center = CGPoint(x: sourceRect.midX, y: sourceRect.minY)
        let config = UIEditMenuConfiguration(identifier: NSString(string: "lasso-selection"),
                                             sourcePoint: center)
        config.preferredArrowDirection = .down
        interaction.presentEditMenu(with: config)
    }

    func presentPasteShortcut(in view: UIView, sourcePoint: CGPoint, onPaste: @escaping () -> Void) {
        dismiss()
        self.hostView = view
        self.sourceRect = CGRect(x: sourcePoint.x - 1, y: sourcePoint.y - 1, width: 2, height: 2)
        self.actions = nil
        self.pasteShortcutAction = onPaste

        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        self.interaction = interaction

        let config = UIEditMenuConfiguration(identifier: NSString(string: "lasso-paste-shortcut"),
                                             sourcePoint: sourcePoint)
        config.preferredArrowDirection = .down
        interaction.presentEditMenu(with: config)
    }

    func dismiss() {
        if let interaction, let hostView {
            interaction.dismissMenu()
            hostView.removeInteraction(interaction)
        }
        interaction = nil
        hostView = nil
        actions = nil
        pasteShortcutAction = nil
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        sourceRect
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        if let pasteShortcutAction {
            return UIMenu(title: "", children: [
                UIAction(title: "붙여넣기",
                         image: UIImage(systemName: "doc.on.clipboard")) { _ in
                    pasteShortcutAction()
                }
            ])
        }
        guard let actions else { return nil }
        var children: [UIMenuElement] = []

        children.append(UIAction(title: "잘라내기",
                                 image: UIImage(systemName: "scissors")) { _ in
            actions.onCut()
        })
        children.append(UIAction(title: "복사",
                                 image: UIImage(systemName: "doc.on.doc")) { _ in
            actions.onCopy()
        })
        if actions.canPaste {
            children.append(UIAction(title: "붙여넣기",
                                     image: UIImage(systemName: "doc.on.clipboard")) { _ in
                actions.onPaste()
            })
        }

        let colorMenu = makeColorMenu(actions: actions)
        children.append(colorMenu)

        children.append(UIAction(title: "삭제",
                                 image: UIImage(systemName: "trash"),
                                 attributes: .destructive) { _ in
            actions.onDelete()
        })

        return UIMenu(title: "", children: children)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in
            guard let self else { return }
            if let interaction = self.interaction, let host = self.hostView {
                host.removeInteraction(interaction)
            }
            self.interaction = nil
            self.hostView = nil
            self.actions = nil
            self.pasteShortcutAction = nil
        }
    }

    private func makeColorMenu(actions: LassoMenuActions) -> UIMenu {
        var children: [UIMenuElement] = PaletteState.defaultPresetColors.enumerated().map { _, color in
            let title = paletteColorTitle(color)
            let image = swatchImage(for: color)
            return UIAction(title: title, image: image) { _ in
                actions.onRecolor(color)
            }
        }
        children.append(UIAction(title: "다른 색…",
                                 image: UIImage(systemName: "paintpalette")) { _ in
            actions.onPickCustomColor()
        })
        return UIMenu(title: "색상 변경",
                      image: UIImage(systemName: "paintpalette"),
                      children: children)
    }

    private func swatchImage(for color: Color) -> UIImage? {
        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(color).cgColor)
            cg.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            cg.setStrokeColor(UIColor.label.withAlphaComponent(0.25).cgColor)
            cg.setLineWidth(0.75)
            cg.strokeEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5))
        }.withRenderingMode(.alwaysOriginal)
    }

    private func paletteColorTitle(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let presets: [(name: String, color: (CGFloat, CGFloat, CGFloat))] = [
            ("검정", (0, 0, 0)),
            ("빨강", (0.85, 0.20, 0.20)),
            ("주황", (0.95, 0.55, 0.10)),
            ("노랑", (0.95, 0.80, 0.20)),
            ("초록", (0.30, 0.70, 0.40)),
            ("파랑", (0.20, 0.50, 0.85)),
            ("보라", (0.55, 0.30, 0.75)),
            ("회색", (0.50, 0.50, 0.55))
        ]
        for preset in presets {
            if abs(preset.color.0 - r) < 0.05,
               abs(preset.color.1 - g) < 0.05,
               abs(preset.color.2 - b) < 0.05 {
                return preset.name
            }
        }
        return ""
    }
}
