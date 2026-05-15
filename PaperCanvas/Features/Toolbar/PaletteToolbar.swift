import SwiftUI

struct PaletteToolbar: View {
    @Bindable var palette: PaletteState
    @State private var showingPenPicker = false
    @State private var editingWidthSlot: Int?
    @State private var editingColorSlot: Int?

    var body: some View {
        HStack(spacing: 10) {
            toolSelector

            if palette.tool.supportsWidth || palette.tool.supportsColor {
                divider
                propertySelector
            }

            divider
            actionGroup
        }
        .padding(.horizontal, 6)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 0.5, height: 28)
    }

    private var toolSelector: some View {
        HStack(spacing: 4) {
            ForEach(ToolKind.allCases) { kind in
                Button {
                    handleToolTap(kind)
                } label: {
                    toolGlyph(for: kind)
                        .frame(width: 38, height: 38)
                        .foregroundStyle(palette.tool == kind ? Color.accentColor : Color.Ink.primary)
                        .background(
                            palette.tool == kind ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: .rect(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(toolLabel(for: kind))
            }
        }
        .popover(isPresented: $showingPenPicker, arrowEdge: .top) {
            penPicker
                .padding(10)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func handleToolTap(_ kind: ToolKind) {
        if kind == .pen, palette.tool == .pen {
            editingWidthSlot = nil
            editingColorSlot = nil
            showingPenPicker = true
            return
        }

        showingPenPicker = false
        editingWidthSlot = nil
        editingColorSlot = nil
        let shouldHaptic = palette.tool != kind
        palette.tool = kind
        if shouldHaptic {
            UIImpactFeedbackGenerator(style: kind.hapticStyle).impactOccurred()
        }
    }

    @ViewBuilder
    private func toolGlyph(for kind: ToolKind) -> some View {
        if kind == .pen {
            penKindGlyph(palette.penKind)
        } else {
            Image(systemName: kind.systemImage)
                .font(.system(size: 18, weight: .medium))
        }
    }

    private var penPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PenKind.allCases) { kind in
                Button {
                    palette.setPenKind(kind)
                    showingPenPicker = false
                } label: {
                    HStack(spacing: 10) {
                        penKindGlyph(kind)
                            .frame(width: 24, height: 24)
                        Text(kind.label)
                            .font(.body)
                        Spacer(minLength: 12)
                        if palette.penKind == kind {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .foregroundStyle(Color.Ink.primary)
                    .frame(width: 180, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func penKindGlyph(_ kind: PenKind) -> some View {
        if kind.usesCustomToolbarIcon {
            FountainPenNibIcon()
                .stroke(style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: kind.systemImage)
                .font(.system(size: 18, weight: .medium))
        }
    }

    private func toolLabel(for kind: ToolKind) -> String {
        kind == .pen ? "\(kind.label), \(palette.penKind.label)" : kind.label
    }

    private var propertySelector: some View {
        HStack(spacing: 8) {
            if palette.tool.supportsWidth {
                widthSlotGroup
            }

            if palette.tool.supportsWidth && palette.tool.supportsColor {
                miniDivider
            }

            if palette.tool.supportsColor {
                colorSlotGroup
            }
        }
    }

    private var miniDivider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 0.5, height: 22)
    }

    private var widthSlotGroup: some View {
        HStack(spacing: 4) {
            ForEach(Array(palette.activeWidthSlots.enumerated()), id: \.offset) { index, slotWidth in
                widthSlotButton(width: slotWidth, index: index)
            }
        }
        .popover(isPresented: widthEditorPresentedBinding, arrowEdge: .top) {
            if let index = validEditingWidthSlot {
                WidthSlotEditor(
                    width: widthBinding(for: index),
                    range: palette.activeWidthRange,
                    color: widthPreviewColor,
                    presetSteps: palette.activeWidthPresetSteps
                )
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func widthSlotButton(width slotWidth: CGFloat, index: Int) -> some View {
        let isSelected = abs(palette.width - slotWidth) < 0.1
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            Capsule()
                .fill(widthPreviewColor)
                .frame(width: max(13, min(slotWidth * 2.0, 30)),
                       height: max(2, min(slotWidth, 12)))
        }
        .frame(width: 38, height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.Rule.hairline,
                        lineWidth: isSelected ? 1.6 : 0.7)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            showingPenPicker = false
            editingColorSlot = nil
            palette.setWidthSlot(slotWidth, at: index)
            editingWidthSlot = index
        }
        .accessibilityLabel("굵기 슬롯 \(index + 1)")
    }

    private var widthPreviewColor: Color {
        palette.tool == .eraser ? Color(.systemGray3) : palette.color
    }

    private var validEditingWidthSlot: Int? {
        guard let editingWidthSlot,
              palette.activeWidthSlots.indices.contains(editingWidthSlot) else {
            return nil
        }
        return editingWidthSlot
    }

    private var widthEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { validEditingWidthSlot != nil },
            set: { isPresented in
                if !isPresented {
                    editingWidthSlot = nil
                }
            }
        )
    }

    private func widthBinding(for index: Int) -> Binding<CGFloat> {
        Binding(
            get: {
                guard palette.activeWidthSlots.indices.contains(index) else {
                    return palette.width
                }
                return palette.activeWidthSlots[index]
            },
            set: { palette.setWidthSlot($0, at: index) }
        )
    }

    private var colorSlotGroup: some View {
        HStack(spacing: 4) {
            ForEach(Array(palette.activeColorSlots.enumerated()), id: \.offset) { index, color in
                colorSlotButton(color, index: index)
            }
        }
        .popover(isPresented: colorEditorPresentedBinding, arrowEdge: .top) {
            if let index = validEditingColorSlot {
                ColorSlotEditor(
                    selectedColor: palette.activeColorSlots[index],
                    presetColors: palette.presetColors,
                    colorHistory: palette.customColorHistory,
                    onSelect: { palette.setColorSlot($0, atIndex: index) },
                    onAddPreset: { palette.addPresetColor($0) }
                )
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func colorSlotButton(_ color: Color, index: Int) -> some View {
        let isSelected = colorsApproximatelyEqual(palette.color, color)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            Circle()
                .fill(color)
                .frame(width: 23, height: 23)
                .overlay(Circle().stroke(Color.Rule.hairline, lineWidth: 0.8))
        }
        .frame(width: 38, height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.Rule.hairline,
                        lineWidth: isSelected ? 1.6 : 0.7)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            showingPenPicker = false
            editingWidthSlot = nil
            palette.setSelectedColor(color)
            editingColorSlot = index
        }
        .accessibilityLabel("색상 슬롯 \(index + 1)")
    }

    private var validEditingColorSlot: Int? {
        guard let editingColorSlot,
              palette.activeColorSlots.indices.contains(editingColorSlot) else {
            return nil
        }
        return editingColorSlot
    }

    private var colorEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { validEditingColorSlot != nil },
            set: { isPresented in
                if !isPresented {
                    editingColorSlot = nil
                }
            }
        )
    }

    private var actionGroup: some View {
        HStack(spacing: 4) {
            Button {
                palette.triggerUndo()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(palette.canUndo ? Color.Ink.primary : Color.Ink.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!palette.canUndo)
            .accessibilityLabel("실행 취소")

            Button {
                palette.triggerRedo()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(palette.canRedo ? Color.Ink.primary : Color.Ink.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!palette.canRedo)
            .accessibilityLabel("다시 실행")
        }
    }

    private func colorsApproximatelyEqual(_ a: Color, _ b: Color) -> Bool {
        let ua = UIColor(a)
        let ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let tol: CGFloat = 0.005
        return abs(r1 - r2) < tol && abs(g1 - g2) < tol && abs(b1 - b2) < tol
    }
}

private struct WidthSlotEditor: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let color: Color
    let presetSteps: [CGFloat]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.Surface.fill)
                        .frame(width: 46, height: 46)
                    Circle()
                        .fill(color)
                        .frame(width: max(4, min(width, 32)),
                               height: max(4, min(width, 32)))
                }

                Text("\(Int(width.rounded())) pt")
                    .font(AppType.bodyEmphasized)
                    .monospacedDigit()
                    .foregroundStyle(Color.Ink.primary)
                    .frame(width: 52, alignment: .leading)
            }

            Slider(value: $width, in: range)
                .frame(width: 220)

            HStack(spacing: 8) {
                ForEach(Array(presetSteps.enumerated()), id: \.offset) { _, step in
                    Button {
                        width = step
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.Surface.fill)
                                .frame(width: 34, height: 34)
                            Circle()
                                .fill(color)
                                .frame(width: max(4, min(step, 24)),
                                       height: max(4, min(step, 24)))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("기본 굵기 \(Int(step.rounded())) pt")
                }
            }
        }
    }
}

private struct ColorSlotEditor: View {
    let selectedColor: Color
    let presetColors: [Color]
    let colorHistory: [Color]
    let onSelect: (Color) -> Void
    let onAddPreset: (Color) -> Void
    @State private var pickerColor: Color

    init(selectedColor: Color,
         presetColors: [Color],
         colorHistory: [Color],
         onSelect: @escaping (Color) -> Void,
         onAddPreset: @escaping (Color) -> Void) {
        self.selectedColor = selectedColor
        self.presetColors = presetColors
        self.colorHistory = colorHistory
        self.onSelect = onSelect
        self.onAddPreset = onAddPreset
        _pickerColor = State(initialValue: selectedColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorGrid(colors: presetColors, allowsAdding: false)

            HStack(spacing: 10) {
                ColorPicker("", selection: $pickerColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 42, height: 42)

                Circle()
                    .fill(pickerColor)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.Rule.hairline, lineWidth: 0.8))

                Button {
                    onSelect(pickerColor)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("색상 적용")

                Button {
                    onAddPreset(pickerColor)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("기본 색상에 추가")
            }
            .frame(width: 248, alignment: .leading)

            if !colorHistory.isEmpty {
                Divider()
                colorGrid(colors: colorHistory, allowsAdding: true)
            }
        }
        .frame(width: 248)
    }

    private func colorGrid(colors: [Color], allowsAdding: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8),
                  alignment: .leading,
                  spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                ZStack(alignment: .topTrailing) {
                    Button {
                        onSelect(color)
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .stroke(isSelected(color) ? Color.accentColor : Color.Rule.hairline,
                                            lineWidth: isSelected(color) ? 2.2 : 0.8)
                            )
                    }
                    .buttonStyle(.plain)

                    if allowsAdding {
                        Button {
                            onAddPreset(color)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.accentColor, Color.Surface.paper)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
                .frame(width: 30, height: 30)
            }
        }
    }

    private func isSelected(_ color: Color) -> Bool {
        let ua = UIColor(selectedColor)
        let ub = UIColor(color)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let tol: CGFloat = 0.005
        return abs(r1 - r2) < tol && abs(g1 - g2) < tol && abs(b1 - b2) < tol
    }
}

private struct FountainPenNibIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = min(rect.width, rect.height) * 0.08
        let minX = rect.minX + inset
        let maxX = rect.maxX - inset
        let minY = rect.minY + inset
        let maxY = rect.maxY - inset
        let midX = rect.midX
        let shoulderY = minY + rect.height * 0.43
        let breatherRadius = rect.width * 0.11

        var path = Path()
        path.move(to: CGPoint(x: midX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: shoulderY))
        path.addLine(to: CGPoint(x: midX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: shoulderY))
        path.closeSubpath()

        path.move(to: CGPoint(x: midX, y: minY + rect.height * 0.20))
        path.addLine(to: CGPoint(x: midX, y: maxY - rect.height * 0.22))
        path.move(to: CGPoint(x: midX, y: maxY))
        path.addLine(to: CGPoint(x: midX - rect.width * 0.12, y: maxY - rect.height * 0.18))
        path.move(to: CGPoint(x: midX, y: maxY))
        path.addLine(to: CGPoint(x: midX + rect.width * 0.12, y: maxY - rect.height * 0.18))
        path.addEllipse(in: CGRect(x: midX - breatherRadius,
                                   y: shoulderY + rect.height * 0.08,
                                   width: breatherRadius * 2,
                                   height: breatherRadius * 2))
        return path
    }
}
