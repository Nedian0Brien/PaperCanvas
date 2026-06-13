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
        case .pen:    return 0.1...20
        case .marker: return 0.1...40
        case .pencil: return 0.1...12
        case .eraser: return 0.1...60
        case .lasso:  return 0.1...20
        }
    }

    var widthSteps: [CGFloat] {
        switch self {
        case .pen:    return [2, 4, 8, 14, 18]
        case .marker: return [8, 16, 24, 32, 40]
        case .pencil: return [1, 3, 5, 8, 11]
        case .eraser: return [10, 20, 32, 44, 56]
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

    var defaultInkTool: InkTool {
        switch self {
        case .pen:    return .pen
        case .marker: return .marker
        case .pencil: return .pencil
        case .eraser: return .eraser
        case .lasso:  return .pen
        }
    }
}

enum PenKind: String, CaseIterable, Identifiable, Codable {
    case ballpoint
    case gelPen
    case fountainPen
    case brushPen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ballpoint:   return "볼펜"
        case .gelPen:      return "젤펜"
        case .fountainPen: return "만년필"
        case .brushPen:    return "붓펜"
        }
    }

    var systemImage: String {
        switch self {
        case .ballpoint:   return "applepencil.tip"
        case .gelPen:      return "scribble.variable"
        case .fountainPen: return "pencil.tip"
        case .brushPen:    return "paintbrush.pointed"
        }
    }

    var usesCustomToolbarIcon: Bool {
        self == .fountainPen
    }

    var inkTool: InkTool {
        switch self {
        case .ballpoint:   return .pen
        case .gelPen:      return .gelPen
        case .fountainPen: return .fountainPen
        case .brushPen:    return .brushPen
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .ballpoint:   return 4
        case .gelPen:      return 4
        case .fountainPen: return 5
        case .brushPen:    return 7
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .ballpoint:   return 0.1...14
        case .gelPen:      return 0.1...16
        case .fountainPen: return 0.1...18
        case .brushPen:    return 0.1...28
        }
    }

    var widthSteps: [CGFloat] {
        switch self {
        case .ballpoint:   return [2, 4, 7, 10, 13]
        case .gelPen:      return [2, 4, 8, 12, 15]
        case .fountainPen: return [2, 5, 9, 13, 17]
        case .brushPen:    return [4, 7, 14, 21, 27]
        }
    }

    var hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .ballpoint:   return .light
        case .gelPen:      return .soft
        case .fountainPen: return .medium
        case .brushPen:    return .rigid
        }
    }
}

enum EraserMode: String, CaseIterable, Identifiable, Codable {
    case pixel
    case element

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pixel:   return "픽셀 지우개"
        case .element: return "요소 지우개"
        }
    }

    var shortLabel: String {
        switch self {
        case .pixel:   return "픽셀"
        case .element: return "요소"
        }
    }

    var systemImage: String {
        switch self {
        case .pixel:   return "square.grid.3x3"
        case .element: return "eraser"
        }
    }

    var eraserType: PKEraserTool.EraserType {
        switch self {
        case .pixel:   return .bitmap
        case .element: return .vector
        }
    }
}

enum LassoMode: String, CaseIterable, Identifiable, Codable {
    case freeform
    case rectangle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .freeform:  return "자유 올가미"
        case .rectangle: return "직사각형 올가미"
        }
    }

    var shortLabel: String {
        switch self {
        case .freeform:  return "자유"
        case .rectangle: return "직각"
        }
    }

    var systemImage: String {
        switch self {
        case .freeform:  return "lasso"
        case .rectangle: return "rectangle.dashed"
        }
    }
}

enum ActiveCanvas: String, Codable {
    case main
    case pdfInk
}

struct MarkerSubmode: Codable, Equatable {
    var inkEnabled: Bool
    var highlightEnabled: Bool
    var regionEnabled: Bool

    static let allEnabled = MarkerSubmode(inkEnabled: true,
                                          highlightEnabled: true,
                                          regionEnabled: true)
}

@Observable
@MainActor
final class PaletteState {
    private static let storeKey = "PaperCanvas.PaletteState.v1"
    static let defaultPresetColors = Color.defaultPresets

    var tool: ToolKind = .pen {
        didSet {
            guard tool != oldValue else { return }
            previousTool = oldValue
            storeCurrentWidth(for: oldValue)
            width = currentStoredWidth
            // Marker doubles as a highlighter — if the user hasn't picked an
            // explicitly bright color yet, default to yellow so highlights and
            // anchor overlays are readable instead of appearing as dark boxes.
            if tool == .marker, isColorTooDarkForHighlight(color) {
                color = PaletteState.defaultHighlighterColor
            }
            save()
        }
    }

    static let defaultHighlighterColor = Color(red: 0.98, green: 0.83, blue: 0.20)

    private func isColorTooDarkForHighlight(_ color: Color) -> Bool {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Perceived luminance — anything substantially below mid-tone won't
        // read as a highlight even after the alpha pass.
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.45
    }
    private(set) var previousTool: ToolKind?

    var penKind: PenKind = .ballpoint {
        didSet {
            guard penKind != oldValue else { return }
            if tool == .pen {
                penWidths[oldValue] = width
                width = penWidths[penKind] ?? penKind.defaultWidth
            }
            save()
        }
    }

    var eraserMode: EraserMode = .element {
        didSet {
            guard eraserMode != oldValue else { return }
            save()
        }
    }

    var lassoMode: LassoMode = .freeform {
        didSet {
            guard lassoMode != oldValue else { return }
            save()
        }
    }

    var markerSubmode: MarkerSubmode = .allEnabled {
        didSet {
            guard markerSubmode != oldValue else { return }
            save()
        }
    }

    var toolSettings: InkToolSettings {
        activeToolSettings
    }

    var color: Color = .black {
        didSet { save() }
    }

    var width: CGFloat = ToolKind.pen.defaultWidth {
        didSet {
            storeCurrentWidth(for: tool)
        }
    }

    var presetColors: [Color] = Color.defaultPresets {
        didSet { save() }
    }
    var customColorHistory: [Color] = [] {
        didSet { save() }
    }

    var undoTrigger: UUID?
    var redoTrigger: UUID?
    var lastActiveCanvas: ActiveCanvas = .main
    var isStrokeInProgress: Bool = false

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
    private var penWidths: [PenKind: CGFloat] = Dictionary(
        uniqueKeysWithValues: PenKind.allCases.map { ($0, $0.defaultWidth) }
    )
    private var widthSlots: [ToolKind: [CGFloat]] = Dictionary(
        uniqueKeysWithValues: ToolKind.allCases.map { ($0, Array($0.widthSteps.prefix(3))) }
    )
    private var penWidthSlots: [PenKind: [CGFloat]] = Dictionary(
        uniqueKeysWithValues: PenKind.allCases.map { ($0, Array($0.widthSteps.prefix(3))) }
    )
    private var colorSlots: [Color] = Array(Color.defaultPresets.prefix(3))
    private var toolSettingsByTool: [ToolKind: InkToolSettings] = Dictionary(
        uniqueKeysWithValues: ToolKind.allCases.map { kind in
            (kind, InkToolSettings.defaultSettings(for: kind.defaultInkTool))
        }
    )
    private var toolSettingsByPenKind: [PenKind: InkToolSettings] = Dictionary(
        uniqueKeysWithValues: PenKind.allCases.map { kind in
            (kind, InkToolSettings.defaultSettings(for: kind.inkTool))
        }
    )

    init() { load() }

    func setWidth(_ value: CGFloat) {
        width = value
        save()
    }

    func setWidthSlot(_ value: CGFloat, at index: Int) {
        guard (0..<3).contains(index) else { return }
        let clamped = clamp(value, to: activeWidthRange)
        var slots = activeWidthSlots
        slots[index] = clamped
        if tool == .pen {
            penWidthSlots[penKind] = slots
        } else {
            widthSlots[tool] = slots
        }
        width = clamped
        save()
    }

    func setSelectedColor(_ color: Color) {
        self.color = color
        recordCustomColorIfNeeded(color)
        save()
    }

    func setPenKind(_ kind: PenKind) {
        guard penKind != kind else { return }
        penKind = kind
        UIImpactFeedbackGenerator(style: kind.hapticStyle).impactOccurred()
    }

    func setEraserMode(_ mode: EraserMode) {
        guard eraserMode != mode else { return }
        eraserMode = mode
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setLassoMode(_ mode: LassoMode) {
        guard lassoMode != mode else { return }
        lassoMode = mode
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setMarkerSubmode(_ submode: MarkerSubmode) {
        guard markerSubmode != submode else { return }
        markerSubmode = submode
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setToolSettings(_ settings: InkToolSettings, for tool: ToolKind) {
        let clamped = settings.clamped
        if tool == .pen {
            guard activeToolSettings != clamped else { return }
            toolSettingsByPenKind[penKind] = clamped
        } else {
            guard (toolSettingsByTool[tool] ?? InkToolSettings.defaultSettings(for: tool.defaultInkTool)) != clamped else { return }
            toolSettingsByTool[tool] = clamped
        }
        save()
    }

    func setPressureSensitivity(_ value: CGFloat, for tool: ToolKind) {
        var settings = settings(for: tool)
        settings.pressureSensitivity = value
        setToolSettings(settings, for: tool)
    }

    func setTextureStrength(_ value: CGFloat, for tool: ToolKind) {
        var settings = settings(for: tool)
        settings.textureStrength = value
        setToolSettings(settings, for: tool)
    }

    func setTextureStyle(_ style: InkTextureStyle, for tool: ToolKind) {
        var settings = settings(for: tool)
        settings.textureStyle = style
        setToolSettings(settings, for: tool)
    }

    func settings(for tool: ToolKind) -> InkToolSettings {
        if tool == .pen {
            return toolSettingsByPenKind[penKind] ?? InkToolSettings.defaultSettings(for: penKind.inkTool)
        }
        return toolSettingsByTool[tool] ?? InkToolSettings.defaultSettings(for: tool.defaultInkTool)
    }

    func settings(for inkTool: InkTool) -> InkToolSettings {
        switch inkTool {
        case .gelPen:
            return toolSettingsByPenKind[.gelPen] ?? InkToolSettings.defaultSettings(for: inkTool)
        case .fountainPen:
            return toolSettingsByPenKind[.fountainPen] ?? InkToolSettings.defaultSettings(for: inkTool)
        case .brushPen:
            return toolSettingsByPenKind[.brushPen] ?? InkToolSettings.defaultSettings(for: inkTool)
        case .pen:
            return toolSettingsByPenKind[penKind] ?? InkToolSettings.defaultSettings(for: inkTool)
        case .pencil:
            return toolSettingsByTool[.pencil] ?? InkToolSettings.defaultSettings(for: inkTool)
        case .marker, .highlighter:
            return toolSettingsByTool[.marker] ?? InkToolSettings.defaultSettings(for: inkTool)
        case .eraser:
            return toolSettingsByTool[.eraser] ?? InkToolSettings.defaultSettings(for: inkTool)
        }
    }

    func settings(for kind: PenKind) -> InkToolSettings {
        toolSettingsByPenKind[kind] ?? InkToolSettings.defaultSettings(for: kind.inkTool)
    }

    private var activeToolSettings: InkToolSettings {
        settings(for: tool)
    }

    func setPresetColor(_ color: Color, atIndex index: Int) {
        guard presetColors.indices.contains(index) else { return }
        presetColors[index] = color
        customColorHistory.removeAll { colorsApproximatelyEqual($0, color) }
    }

    func setColorSlot(_ color: Color, atIndex index: Int) {
        guard (0..<3).contains(index) else { return }
        colorSlots[index] = color
        setSelectedColor(color)
    }

    func addPresetColor(_ color: Color) {
        guard !presetColors.contains(where: { colorsApproximatelyEqual($0, color) }) else {
            customColorHistory.removeAll { colorsApproximatelyEqual($0, color) }
            save()
            return
        }
        presetColors.append(color)
        customColorHistory.removeAll { colorsApproximatelyEqual($0, color) }
        save()
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
            return PKEraserTool(eraserMode.eraserType)
        case .lasso:
            return PKLassoTool()
        }
    }

    var activeWidthRange: ClosedRange<CGFloat> {
        tool == .pen ? penKind.widthRange : tool.widthRange
    }

    var activeWidthSteps: [CGFloat] {
        activeWidthSlots
    }

    var activeWidthPresetSteps: [CGFloat] {
        let defaults = tool == .pen ? penKind.widthSteps : tool.widthSteps
        return normalizedPresetSteps(defaults, range: activeWidthRange)
    }

    var activeWidthSlots: [CGFloat] {
        let stored = tool == .pen ? penWidthSlots[penKind] : widthSlots[tool]
        let defaults = tool == .pen ? penKind.widthSteps : tool.widthSteps
        return normalizedSlots(stored ?? defaults, defaults: defaults, range: activeWidthRange)
    }

    var activeColorSlots: [Color] {
        var slots = Array(colorSlots.prefix(3))
        while slots.count < 3 {
            slots.append(.black)
        }
        return slots
    }

    private var currentStoredWidth: CGFloat {
        tool == .pen ? (penWidths[penKind] ?? penKind.defaultWidth) : (widths[tool] ?? tool.defaultWidth)
    }

    private func storeCurrentWidth(for tool: ToolKind) {
        if tool == .pen {
            penWidths[penKind] = width
        } else {
            widths[tool] = width
        }
    }

    private func normalizedSlots(_ slots: [CGFloat],
                                 defaults: [CGFloat],
                                 range: ClosedRange<CGFloat>) -> [CGFloat] {
        var output = Array(slots.prefix(3))
        while output.count < 3 {
            let fallback = defaults.indices.contains(output.count) ? defaults[output.count] : range.lowerBound
            output.append(fallback)
        }
        return output.map { clamp($0, to: range) }
    }

    private func normalizedPresetSteps(_ steps: [CGFloat], range: ClosedRange<CGFloat>) -> [CGFloat] {
        var output = Array(steps.prefix(5))
        while output.count < 5 {
            let fraction = CGFloat(output.count) / 4
            output.append(range.lowerBound + (range.upperBound - range.lowerBound) * fraction)
        }
        return output.map { clamp($0, to: range) }
    }

    private func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func recordCustomColorIfNeeded(_ color: Color) {
        guard !presetColors.contains(where: { colorsApproximatelyEqual($0, color) }) else {
            customColorHistory.removeAll { colorsApproximatelyEqual($0, color) }
            return
        }
        customColorHistory.removeAll { colorsApproximatelyEqual($0, color) }
        customColorHistory.insert(color, at: 0)
        if customColorHistory.count > 12 {
            customColorHistory.removeLast(customColorHistory.count - 12)
        }
    }

    private func colorsApproximatelyEqual(_ a: Color, _ b: Color) -> Bool {
        let ca = ColorComponents.from(a)
        let cb = ColorComponents.from(b)
        let tol: CGFloat = 0.005
        return abs(ca.r - cb.r) < tol &&
               abs(ca.g - cb.g) < tol &&
               abs(ca.b - cb.b) < tol &&
               abs(ca.a - cb.a) < tol
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
        var penKind: String?
        var eraserMode: String?
        var lassoMode: String?
        var markerSubmode: MarkerSubmode?
        var color: ColorComponents
        var widths: [String: CGFloat]
        var penWidths: [String: CGFloat]?
        var widthSlots: [String: [CGFloat]]?
        var penWidthSlots: [String: [CGFloat]]?
        var colorSlots: [ColorComponents]?
        var customColorHistory: [ColorComponents]?
        var presetColors: [ColorComponents]
        var toolSettingsByTool: [String: InkToolSettings]?
        var toolSettingsByPenKind: [String: InkToolSettings]?
    }

    private func save() {
        let snap = Snapshot(
            tool: tool.rawValue,
            penKind: penKind.rawValue,
            eraserMode: eraserMode.rawValue,
            lassoMode: lassoMode.rawValue,
            markerSubmode: markerSubmode,
            color: ColorComponents.from(color),
            widths: Dictionary(uniqueKeysWithValues: widths.map { ($0.key.rawValue, $0.value) }),
            penWidths: Dictionary(uniqueKeysWithValues: penWidths.map { ($0.key.rawValue, $0.value) }),
            widthSlots: Dictionary(uniqueKeysWithValues: widthSlots.map { ($0.key.rawValue, $0.value) }),
            penWidthSlots: Dictionary(uniqueKeysWithValues: penWidthSlots.map { ($0.key.rawValue, $0.value) }),
            colorSlots: colorSlots.map { ColorComponents.from($0) },
            customColorHistory: customColorHistory.map { ColorComponents.from($0) },
            presetColors: presetColors.map { ColorComponents.from($0) },
            toolSettingsByTool: Dictionary(uniqueKeysWithValues: toolSettingsByTool.map { ($0.key.rawValue, $0.value.clamped) }),
            toolSettingsByPenKind: Dictionary(uniqueKeysWithValues: toolSettingsByPenKind.map { ($0.key.rawValue, $0.value.clamped) })
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
        if let savedPenWidths = snap.penWidths {
            for (k, v) in savedPenWidths {
                if let kind = PenKind(rawValue: k) {
                    penWidths[kind] = v
                }
            }
        } else if let legacyPenWidth = snap.widths[ToolKind.pen.rawValue] {
            penWidths[.ballpoint] = legacyPenWidth
        }
        if let savedWidthSlots = snap.widthSlots {
            for (k, v) in savedWidthSlots {
                if let kind = ToolKind(rawValue: k) {
                    widthSlots[kind] = normalizedSlots(v,
                                                        defaults: kind.widthSteps,
                                                        range: kind.widthRange)
                }
            }
        }
        if let savedPenWidthSlots = snap.penWidthSlots {
            for (k, v) in savedPenWidthSlots {
                if let kind = PenKind(rawValue: k) {
                    penWidthSlots[kind] = normalizedSlots(v,
                                                          defaults: kind.widthSteps,
                                                          range: kind.widthRange)
                }
            }
        }
        if let savedToolSettings = snap.toolSettingsByTool {
            for (k, v) in savedToolSettings {
                if let kind = ToolKind(rawValue: k) {
                    toolSettingsByTool[kind] = v.clamped
                }
            }
        }
        if let savedPenToolSettings = snap.toolSettingsByPenKind {
            for (k, v) in savedPenToolSettings {
                if let kind = PenKind(rawValue: k) {
                    toolSettingsByPenKind[kind] = v.clamped
                }
            }
        }
        if let savedPenKind = snap.penKind,
           let kind = PenKind(rawValue: savedPenKind) {
            penKind = kind
        }
        if let savedEraserMode = snap.eraserMode,
           let mode = EraserMode(rawValue: savedEraserMode) {
            eraserMode = mode
        }
        if let savedLassoMode = snap.lassoMode,
           let mode = LassoMode(rawValue: savedLassoMode) {
            lassoMode = mode
        }
        if let savedMarkerSubmode = snap.markerSubmode {
            markerSubmode = savedMarkerSubmode
        }
        if let kind = ToolKind(rawValue: snap.tool) {
            tool = kind
            width = currentStoredWidth
        }
        color = snap.color.color
        if !snap.presetColors.isEmpty {
            presetColors = snap.presetColors.map { $0.color }
        }
        if let savedColorSlots = snap.colorSlots {
            let slots = savedColorSlots.map { $0.color }
            if !slots.isEmpty {
                colorSlots = normalizedColorSlots(slots)
            }
        } else {
            colorSlots = normalizedColorSlots(Array(presetColors.prefix(3)))
        }
        if let savedHistory = snap.customColorHistory {
            customColorHistory = savedHistory
                .map { $0.color }
                .filter { color in !presetColors.contains(where: { colorsApproximatelyEqual($0, color) }) }
        }
    }

    private func normalizedColorSlots(_ slots: [Color]) -> [Color] {
        var output = Array(slots.prefix(3))
        while output.count < 3 {
            let fallback = presetColors.indices.contains(output.count) ? presetColors[output.count] : .black
            output.append(fallback)
        }
        return output
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
