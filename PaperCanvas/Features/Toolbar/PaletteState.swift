import SwiftUI
import PencilKit
import UIKit

enum ToolKind: String, CaseIterable, Identifiable, Codable {
    case pen
    case marker
    case pencil
    case eraser
    case lasso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen:    return "펜"
        case .marker: return "형광펜"
        case .pencil: return "연필"
        case .eraser: return "지우개"
        case .lasso:  return "올가미"
        }
    }

    var systemImage: String {
        switch self {
        case .pen:    return "applepencil.tip"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .lasso:  return "lasso"
        }
    }

    var supportsWidth: Bool { self != .lasso }
    var supportsColor: Bool { self != .eraser && self != .lasso }

    var defaultWidth: CGFloat {
        switch self {
        case .pen:    return 4
        case .marker: return 18
        case .pencil: return 3
        case .eraser: return 20
        case .lasso:  return 4
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen:    return 1...20
        case .marker: return 4...40
        case .pencil: return 1...12
        case .eraser: return 6...60
        case .lasso:  return 1...20
        }
    }

    var widthSteps: [CGFloat] {
        switch self {
        case .pen:    return [2, 4, 8, 14]
        case .marker: return [8, 16, 24, 36]
        case .pencil: return [1, 3, 6, 10]
        case .eraser: return [10, 20, 35, 55]
        case .lasso:  return [4]
        }
    }

    var hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .pen:    return .light
        case .marker: return .medium
        case .pencil: return .rigid
        case .eraser: return .heavy
        case .lasso:  return .soft
        }
    }
}

enum ActiveCanvas: String, Codable {
    case main
    case pdfInk
}

@Observable
@MainActor
final class PaletteState {
    private static let storeKey = "PaperCanvas.PaletteState.v1"

    var tool: ToolKind = .pen {
        didSet {
            guard tool != oldValue else { return }
            previousTool = oldValue
            widths[oldValue] = width
            width = widths[tool] ?? tool.defaultWidth
            save()
        }
    }
    private(set) var previousTool: ToolKind?

    var color: Color = .black {
        didSet { save() }
    }

    var width: CGFloat = ToolKind.pen.defaultWidth {
        didSet {
            widths[tool] = width
        }
    }

    var presetColors: [Color] = Color.defaultPresets {
        didSet { save() }
    }

    var undoTrigger: UUID?
    var redoTrigger: UUID?
    var lastActiveCanvas: ActiveCanvas = .main

    var mainCanUndo: Bool = false
    var mainCanRedo: Bool = false
    var pdfCanUndo: Bool = false
    var pdfCanRedo: Bool = false

    var canUndo: Bool {
        lastActiveCanvas == .main ? mainCanUndo : pdfCanUndo
    }
    var canRedo: Bool {
        lastActiveCanvas == .main ? mainCanRedo : pdfCanRedo
    }

    private var widths: [ToolKind: CGFloat] = Dictionary(
        uniqueKeysWithValues: ToolKind.allCases.map { ($0, $0.defaultWidth) }
    )

    init() { load() }

    func setWidth(_ value: CGFloat) {
        width = value
        save()
    }

    func setPresetColor(_ color: Color, atIndex index: Int) {
        guard presetColors.indices.contains(index) else { return }
        presetColors[index] = color
    }

    func triggerUndo() {
        undoTrigger = UUID()
    }

    func triggerRedo() {
        redoTrigger = UUID()
    }

    func switchToPreviousTool() {
        let target: ToolKind
        if let prev = previousTool, prev != tool {
            target = prev
        } else {
            target = (tool == .eraser) ? .pen : .eraser
        }
        tool = target
        UIImpactFeedbackGenerator(style: target.hapticStyle).impactOccurred()
    }

    var pkTool: PKTool {
        let uiColor = UIColor(color)
        switch tool {
        case .pen:
            return PKInkingTool(.pen, color: uiColor, width: width)
        case .marker:
            return PKInkingTool(.marker, color: uiColor.withAlphaComponent(0.45), width: width)
        case .pencil:
            return PKInkingTool(.pencil, color: uiColor, width: width)
        case .eraser:
            return PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        }
    }

    private struct ColorComponents: Codable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat

        static func from(_ color: Color) -> ColorComponents {
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return ColorComponents(r: r, g: g, b: b, a: a)
        }

        var color: Color {
            Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
    }

    private struct Snapshot: Codable {
        var tool: String
        var color: ColorComponents
        var widths: [String: CGFloat]
        var presetColors: [ColorComponents]
    }

    private func save() {
        let snap = Snapshot(
            tool: tool.rawValue,
            color: ColorComponents.from(color),
            widths: Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) }),
            presetColors: presetColors.map { ColorComponents.from($0) }
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        for (k, v) in snap.widths {
            if let kind = ToolKind(rawValue: k) {
                widths[kind] = v
            }
        }
        if let kind = ToolKind(rawValue: snap.tool) {
            tool = kind
            width = widths[kind] ?? kind.defaultWidth
        }
        color = snap.color.color
        if snap.presetColors.count == Color.defaultPresets.count {
            presetColors = snap.presetColors.map { $0.color }
        }
    }
}

extension Color {
    static let defaultPresets: [Color] = [
        .black,
        Color(red: 0.85, green: 0.20, blue: 0.20),
        Color(red: 0.95, green: 0.55, blue: 0.10),
        Color(red: 0.95, green: 0.80, blue: 0.20),
        Color(red: 0.30, green: 0.70, blue: 0.40),
        Color(red: 0.20, green: 0.50, blue: 0.85),
        Color(red: 0.55, green: 0.30, blue: 0.75),
        Color(red: 0.50, green: 0.50, blue: 0.55)
    ]
}
