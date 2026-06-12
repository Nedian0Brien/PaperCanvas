import SwiftUI
import UIKit

enum PaletteToolbarLayout {
    case horizontal
    case vertical
}

struct PaletteToolbar: View {
    @Bindable var palette: PaletteState
    var layout: PaletteToolbarLayout = .horizontal
    var popoverArrowEdge: Edge = .top
    @State private var activeEditor: PaletteEditor?
    @State private var selectedWidthSlotIndex: Int?
    @State private var selectedColorSlotIndex: Int?

    private enum ToolbarMetrics {
        static let itemSize: CGFloat = 38
        static let itemSpacing: CGFloat = 4
        static let verticalControlWidth: CGFloat = 44
        static let verticalItemHeight: CGFloat = 50
        static let verticalRailHorizontalPadding: CGFloat = 4
        static let verticalRailWidth: CGFloat = verticalControlWidth + verticalRailHorizontalPadding * 2
        static let slotGroupWidth: CGFloat = itemSize * 3 + itemSpacing * 2
        static let modeGroupWidth: CGFloat = 154
        static let verticalModeWidth: CGFloat = verticalControlWidth
        static let verticalModeHeight: CGFloat = verticalItemHeight
        static let verticalWidthSlotGroupHeight: CGFloat = verticalItemHeight * 3
        static let verticalModeGroupHeight: CGFloat = verticalModeHeight * 2
        static let propertyGap: CGFloat = 8
        static let miniDividerWidth: CGFloat = 0.5
        static let verticalPropertySelectorHeight: CGFloat = verticalWidthSlotGroupHeight + verticalModeGroupHeight + propertyGap * 2 + miniDividerWidth
        static let doubleSlotGroupWidth: CGFloat = slotGroupWidth * 2 + propertyGap * 2 + miniDividerWidth
        static let selectorAnimation = Animation.spring(response: 0.24, dampingFraction: 0.82)
    }

    private enum PaletteEditor: Identifiable, Equatable {
        case pen
        case marker
        case pencil
        case width(Int)
        case color(Int)

        var id: String {
            switch self {
            case .pen:
                return "pen"
            case .marker:
                return "marker"
            case .pencil:
                return "pencil"
            case .width(let index):
                return "width-\(index)"
            case .color(let index):
                return "color-\(index)"
            }
        }
    }

    var body: some View {
        switch layout {
        case .horizontal:
            horizontalToolbar
        case .vertical:
            verticalToolbar
        }
    }

    private var horizontalToolbar: some View {
        HStack(spacing: 10) {
            toolSelector

            divider
            propertySelector

            divider
            actionGroup
        }
        .padding(.horizontal, 6)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var verticalToolbar: some View {
        VStack(spacing: 8) {
            verticalToolSelector

            horizontalDivider
            verticalPropertySelector

            horizontalDivider
            verticalActionGroup
        }
        .padding(.horizontal, ToolbarMetrics.verticalRailHorizontalPadding)
        .padding(.vertical, 6)
        .fixedSize()
        .frame(width: ToolbarMetrics.verticalRailWidth)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 0.5, height: 28)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 24, height: 0.5)
    }

    private var toolSelector: some View {
        RetappableSegmentedPicker(
            segments: toolSegments,
            selectedIndex: ToolKind.allCases.firstIndex(of: palette.tool),
            accessibilityLabel: "도구",
            onSelect: { selectTool(ToolKind.allCases[$0]) },
            onReselect: { handleToolReselect(ToolKind.allCases[$0]) }
        )
        .frame(width: CGFloat(ToolKind.allCases.count) * ToolbarMetrics.itemSize,
               height: ToolbarMetrics.itemSize)
        .popover(isPresented: penEditorPresentedBinding,
                 attachmentAnchor: .point(toolPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            drawingToolSettingsEditor(for: .pen)
                .padding(14)
                .presentationCompactAdaptation(.popover)
        }
        .popover(isPresented: markerEditorPresentedBinding,
                 attachmentAnchor: .point(markerPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            drawingToolSettingsEditor(for: .marker)
                .padding(14)
                .presentationCompactAdaptation(.popover)
        }
        .popover(isPresented: pencilEditorPresentedBinding,
                 attachmentAnchor: .point(pencilPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            drawingToolSettingsEditor(for: .pencil)
                .padding(14)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var toolSegments: [SegmentedPaletteItem] {
        ToolKind.allCases.map { kind in
            let systemName = kind == .pen ? palette.penKind.systemImage : kind.systemImage
            return SegmentedPaletteItem(
                id: kind.id,
                image: UIImage(systemName: systemName),
                accessibilityLabel: toolLabel(for: kind)
            )
        }
    }

    private func selectTool(_ kind: ToolKind) {
        guard palette.tool != kind else {
            handleToolReselect(kind)
            return
        }
        closePropertyEditors()
        withAnimation(ToolbarMetrics.selectorAnimation) {
            palette.tool = kind
        }
        if kind.supportsColor {
            activeEditor = editor(for: kind)
        }
        UIImpactFeedbackGenerator(style: kind.hapticStyle).impactOccurred()
    }

    private func handleToolReselect(_ kind: ToolKind) {
        closePropertyEditors()
        activeEditor = editor(for: kind)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func editor(for kind: ToolKind) -> PaletteEditor? {
        switch kind {
        case .pen:
            return .pen
        case .marker:
            return .marker
        case .pencil:
            return .pencil
        case .eraser, .lasso:
            return nil
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

    private var verticalToolSelector: some View {
        VerticalRetappableSegmentedPicker(
            segments: toolSegments,
            selectedIndex: ToolKind.allCases.firstIndex(of: palette.tool),
            accessibilityLabel: "도구",
            segmentSize: CGSize(width: ToolbarMetrics.verticalControlWidth,
                                height: ToolbarMetrics.verticalItemHeight),
            onSelect: { selectTool(ToolKind.allCases[$0]) },
            onReselect: { handleToolReselect(ToolKind.allCases[$0]) }
        )
        .popover(isPresented: penEditorPresentedBinding,
                 attachmentAnchor: .point(verticalToolPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            drawingToolSettingsEditor(for: .pen)
                .padding(14)
                .presentationCompactAdaptation(.popover)
        }
        .popover(isPresented: markerEditorPresentedBinding,
                 attachmentAnchor: .point(verticalMarkerPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            drawingToolSettingsEditor(for: .marker)
                .padding(14)
                .presentationCompactAdaptation(.popover)
        }
        .popover(isPresented: pencilEditorPresentedBinding,
                 attachmentAnchor: .point(verticalPencilPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            drawingToolSettingsEditor(for: .pencil)
                .padding(14)
                .presentationCompactAdaptation(.popover)
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

    private var penEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeEditor == .pen },
            set: { isPresented in
                if !isPresented, activeEditor == .pen {
                    activeEditor = nil
                }
            }
        )
    }

    private var markerEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeEditor == .marker },
            set: { isPresented in
                if !isPresented, activeEditor == .marker {
                    activeEditor = nil
                }
            }
        )
    }

    private var pencilEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeEditor == .pencil },
            set: { isPresented in
                if !isPresented, activeEditor == .pencil {
                    activeEditor = nil
                }
            }
        )
    }

    private func drawingToolSettingsEditor(for tool: ToolKind) -> some View {
        DrawingToolSettingsEditor(
            tool: tool,
            penKind: palette.penKind,
            width: drawingToolWidthBinding(for: tool),
            widthRange: widthRange(for: tool),
            color: drawingToolColorBinding,
            presetColors: palette.presetColors,
            markerSubmode: palette.markerSubmode,
            onSelectPenKind: { palette.setPenKind($0) },
            onSetMarkerSubmode: { palette.setMarkerSubmode($0) }
        )
    }

    private func drawingToolWidthBinding(for tool: ToolKind) -> Binding<CGFloat> {
        Binding(
            get: { palette.width },
            set: { palette.setWidth(clamp($0, to: widthRange(for: tool))) }
        )
    }

    private var drawingToolColorBinding: Binding<Color> {
        Binding(
            get: { palette.color },
            set: { palette.setSelectedColor($0) }
        )
    }

    private func widthRange(for tool: ToolKind) -> ClosedRange<CGFloat> {
        tool == .pen ? palette.penKind.widthRange : tool.widthRange
    }

    private var toolPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: ToolKind.allCases.firstIndex(of: .pen),
            count: ToolKind.allCases.count
        )
    }

    private var verticalToolPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: ToolKind.allCases.firstIndex(of: .pen),
            count: ToolKind.allCases.count,
            axis: .vertical
        )
    }

    private var markerPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: ToolKind.allCases.firstIndex(of: .marker),
            count: ToolKind.allCases.count
        )
    }

    private var verticalMarkerPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: ToolKind.allCases.firstIndex(of: .marker),
            count: ToolKind.allCases.count,
            axis: .vertical
        )
    }

    private var pencilPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: ToolKind.allCases.firstIndex(of: .pencil),
            count: ToolKind.allCases.count
        )
    }

    private var verticalPencilPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: ToolKind.allCases.firstIndex(of: .pencil),
            count: ToolKind.allCases.count,
            axis: .vertical
        )
    }

    private var propertySelector: some View {
        HStack(spacing: ToolbarMetrics.propertyGap) {
            switch palette.tool {
            case .pen, .marker, .pencil:
                widthSlotGroup
                miniDivider
                colorSlotGroup
            case .eraser:
                widthSlotGroup
                miniDivider
                eraserModeGroup
            case .lasso:
                lassoModeGroup
            }
        }
    }

    private var verticalPropertySelector: some View {
        VStack(spacing: ToolbarMetrics.propertyGap) {
            switch palette.tool {
            case .pen, .marker, .pencil:
                verticalWidthSlotGroup
                horizontalMiniDivider
                verticalColorSlotGroup
            case .eraser:
                verticalWidthSlotGroup
                horizontalMiniDivider
                verticalEraserModeGroup
            case .lasso:
                verticalLassoModeGroup
            }
        }
        .frame(height: ToolbarMetrics.verticalPropertySelectorHeight, alignment: .top)
    }

    private var miniDivider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 0.5, height: 22)
    }

    private var horizontalMiniDivider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 28, height: 0.5)
    }

    private var widthSlotGroup: some View {
        RetappableSegmentedPicker(
            segments: widthSegments,
            selectedIndex: resolvedSelectedWidthSlotIndex,
            accessibilityLabel: "굵기",
            onSelect: selectWidthSlot(at:),
            onReselect: openWidthEditor(at:)
        )
        .frame(width: ToolbarMetrics.slotGroupWidth)
        .popover(isPresented: widthEditorPresentedBinding,
                 attachmentAnchor: .point(widthPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            if let index = activeWidthEditorIndex {
                WidthSlotEditor(
                    width: widthBinding(for: index),
                    range: palette.activeWidthRange,
                    color: widthPreviewColor
                )
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var verticalWidthSlotGroup: some View {
        VerticalRetappableSegmentedPicker(
            segments: widthSegments,
            selectedIndex: resolvedSelectedWidthSlotIndex,
            accessibilityLabel: "굵기",
            segmentSize: CGSize(width: ToolbarMetrics.verticalControlWidth,
                                height: ToolbarMetrics.verticalItemHeight),
            onSelect: selectWidthSlot(at:),
            onReselect: openWidthEditor(at:)
        )
        .popover(isPresented: widthEditorPresentedBinding,
                 attachmentAnchor: .point(verticalWidthPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            if let index = activeWidthEditorIndex {
                WidthSlotEditor(
                    width: widthBinding(for: index),
                    range: palette.activeWidthRange,
                    color: widthPreviewColor
                )
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var widthSegments: [SegmentedPaletteItem] {
        palette.activeWidthSlots.enumerated().map { index, slotWidth in
            SegmentedPaletteItem(
                id: "width-\(index)",
                image: widthPreviewImage(width: slotWidth, color: UIColor(widthPreviewColor)),
                accessibilityLabel: "굵기 슬롯 \(index + 1)"
            )
        }
    }

    private func selectWidthSlot(at index: Int) {
        guard palette.activeWidthSlots.indices.contains(index) else { return }
        activeEditor = nil
        selectedWidthSlotIndex = index
        withAnimation(ToolbarMetrics.selectorAnimation) {
            palette.setWidthSlot(palette.activeWidthSlots[index], at: index)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func openWidthEditor(at index: Int) {
        guard palette.activeWidthSlots.indices.contains(index) else { return }
        activeEditor = .width(index)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var widthPreviewColor: Color {
        palette.tool == .eraser ? Color(.systemGray3) : palette.color
    }

    private var resolvedSelectedWidthSlotIndex: Int? {
        let slots = palette.activeWidthSlots
        if let selectedWidthSlotIndex,
           slots.indices.contains(selectedWidthSlotIndex),
           abs(palette.width - slots[selectedWidthSlotIndex]) < 0.1 {
            return selectedWidthSlotIndex
        }

        if case .width(let editingWidthSlot) = activeEditor,
           slots.indices.contains(editingWidthSlot),
           abs(palette.width - slots[editingWidthSlot]) < 0.1 {
            return editingWidthSlot
        }

        return slots.enumerated().first { _, slotWidth in
            abs(palette.width - slotWidth) < 0.1
        }?.offset
    }

    private var activeWidthEditorIndex: Int? {
        guard case .width(let index) = activeEditor,
              palette.activeWidthSlots.indices.contains(index) else {
            return nil
        }
        return index
    }

    private var widthEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeWidthEditorIndex != nil },
            set: { isPresented in
                if !isPresented, case .width = activeEditor {
                    activeEditor = nil
                }
            }
        )
    }

    private var widthPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: activeWidthEditorIndex ?? resolvedSelectedWidthSlotIndex,
            count: palette.activeWidthSlots.count
        )
    }

    private var verticalWidthPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: activeWidthEditorIndex ?? resolvedSelectedWidthSlotIndex,
            count: palette.activeWidthSlots.count,
            axis: .vertical
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
            set: {
                selectedWidthSlotIndex = index
                palette.setWidthSlot($0, at: index)
            }
        )
    }

    private var colorSlotGroup: some View {
        RetappableSegmentedPicker(
            segments: colorSegments,
            selectedIndex: resolvedSelectedColorSlotIndex,
            accessibilityLabel: "색상",
            onSelect: selectColorSlot(at:),
            onReselect: openColorEditor(at:)
        )
        .frame(width: ToolbarMetrics.slotGroupWidth)
        .popover(isPresented: colorEditorPresentedBinding,
                 attachmentAnchor: .point(colorPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            if let index = activeColorEditorIndex {
                ColorSlotEditor(
                    selectedColor: palette.activeColorSlots[index],
                    presetColors: palette.presetColors,
                    colorHistory: palette.customColorHistory,
                    onSelect: {
                        selectedColorSlotIndex = index
                        palette.setColorSlot($0, atIndex: index)
                    },
                    onAddPreset: { palette.addPresetColor($0) }
                )
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var verticalColorSlotGroup: some View {
        VerticalRetappableSegmentedPicker(
            segments: colorSegments,
            selectedIndex: resolvedSelectedColorSlotIndex,
            accessibilityLabel: "색상",
            segmentSize: CGSize(width: ToolbarMetrics.verticalControlWidth,
                                height: ToolbarMetrics.verticalItemHeight),
            onSelect: selectColorSlot(at:),
            onReselect: openColorEditor(at:)
        )
        .popover(isPresented: colorEditorPresentedBinding,
                 attachmentAnchor: .point(verticalColorPopoverAnchor),
                 arrowEdge: popoverArrowEdge) {
            if let index = activeColorEditorIndex {
                ColorSlotEditor(
                    selectedColor: palette.activeColorSlots[index],
                    presetColors: palette.presetColors,
                    colorHistory: palette.customColorHistory,
                    onSelect: {
                        selectedColorSlotIndex = index
                        palette.setColorSlot($0, atIndex: index)
                    },
                    onAddPreset: { palette.addPresetColor($0) }
                )
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var colorSegments: [SegmentedPaletteItem] {
        palette.activeColorSlots.enumerated().map { index, color in
            SegmentedPaletteItem(
                id: "color-\(index)",
                image: colorPreviewImage(color: UIColor(color)),
                accessibilityLabel: "색상 슬롯 \(index + 1)"
            )
        }
    }

    private func selectColorSlot(at index: Int) {
        guard palette.activeColorSlots.indices.contains(index) else { return }
        activeEditor = nil
        selectedColorSlotIndex = index
        withAnimation(ToolbarMetrics.selectorAnimation) {
            palette.setSelectedColor(palette.activeColorSlots[index])
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func openColorEditor(at index: Int) {
        guard palette.activeColorSlots.indices.contains(index) else { return }
        activeEditor = .color(index)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var resolvedSelectedColorSlotIndex: Int? {
        let slots = palette.activeColorSlots
        if let selectedColorSlotIndex,
           slots.indices.contains(selectedColorSlotIndex),
           colorsApproximatelyEqual(palette.color, slots[selectedColorSlotIndex]) {
            return selectedColorSlotIndex
        }

        if case .color(let editingColorSlot) = activeEditor,
           slots.indices.contains(editingColorSlot),
           colorsApproximatelyEqual(palette.color, slots[editingColorSlot]) {
            return editingColorSlot
        }

        return slots.enumerated().first { _, slotColor in
            colorsApproximatelyEqual(palette.color, slotColor)
        }?.offset
    }

    private var activeColorEditorIndex: Int? {
        guard case .color(let index) = activeEditor,
              palette.activeColorSlots.indices.contains(index) else {
            return nil
        }
        return index
    }

    private var colorEditorPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeColorEditorIndex != nil },
            set: { isPresented in
                if !isPresented, case .color = activeEditor {
                    activeEditor = nil
                }
            }
        )
    }

    private var colorPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: activeColorEditorIndex ?? resolvedSelectedColorSlotIndex,
            count: palette.activeColorSlots.count
        )
    }

    private var verticalColorPopoverAnchor: UnitPoint {
        segmentAnchorPoint(
            index: activeColorEditorIndex ?? resolvedSelectedColorSlotIndex,
            count: palette.activeColorSlots.count,
            axis: .vertical
        )
    }

    private var eraserModeGroup: some View {
        RetappableSegmentedPicker(
            segments: eraserModeSegments,
            selectedIndex: EraserMode.allCases.firstIndex(of: palette.eraserMode),
            accessibilityLabel: "지우개 모드",
            onSelect: selectEraserMode(at:),
            onReselect: { _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        )
        .frame(width: ToolbarMetrics.modeGroupWidth)
    }

    private var eraserModeSegments: [SegmentedPaletteItem] {
        EraserMode.allCases.map { mode in
            SegmentedPaletteItem(
                id: mode.id,
                image: modeSegmentImage(systemName: mode.systemImage, title: mode.shortLabel),
                verticalSystemImage: mode.systemImage,
                verticalTitle: mode.shortLabel,
                accessibilityLabel: mode.label
            )
        }
    }

    private var verticalEraserModeGroup: some View {
        VerticalRetappableSegmentedPicker(
            segments: eraserModeSegments,
            selectedIndex: EraserMode.allCases.firstIndex(of: palette.eraserMode),
            accessibilityLabel: "지우개 모드",
            segmentSize: CGSize(width: ToolbarMetrics.verticalModeWidth,
                                height: ToolbarMetrics.verticalModeHeight),
            onSelect: selectEraserMode(at:),
            onReselect: { _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        )
    }

    private func selectEraserMode(at index: Int) {
        guard EraserMode.allCases.indices.contains(index) else { return }
        activeEditor = nil
        withAnimation(ToolbarMetrics.selectorAnimation) {
            palette.setEraserMode(EraserMode.allCases[index])
        }
    }

    private var lassoModeGroup: some View {
        RetappableSegmentedPicker(
            segments: lassoModeSegments,
            selectedIndex: LassoMode.allCases.firstIndex(of: palette.lassoMode),
            accessibilityLabel: "올가미 모드",
            onSelect: selectLassoMode(at:),
            onReselect: { _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        )
        .frame(width: ToolbarMetrics.modeGroupWidth)
    }

    private var lassoModeSegments: [SegmentedPaletteItem] {
        LassoMode.allCases.map { mode in
            SegmentedPaletteItem(
                id: mode.id,
                image: modeSegmentImage(systemName: mode.systemImage, title: mode.shortLabel),
                verticalSystemImage: mode.systemImage,
                verticalTitle: mode.shortLabel,
                accessibilityLabel: mode.label
            )
        }
    }

    private var verticalLassoModeGroup: some View {
        VerticalRetappableSegmentedPicker(
            segments: lassoModeSegments,
            selectedIndex: LassoMode.allCases.firstIndex(of: palette.lassoMode),
            accessibilityLabel: "올가미 모드",
            segmentSize: CGSize(width: ToolbarMetrics.verticalModeWidth,
                                height: ToolbarMetrics.verticalModeHeight),
            onSelect: selectLassoMode(at:),
            onReselect: { _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        )
    }

    private func verticalModeLabel(systemImage: String,
                                   title: String,
                                   isSelected: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(isSelected ? Color.Ink.primary : Color.Ink.secondary)
        .frame(width: ToolbarMetrics.verticalModeWidth,
               height: ToolbarMetrics.verticalModeHeight)
        .contentShape(.rect)
    }

    private func selectLassoMode(at index: Int) {
        guard LassoMode.allCases.indices.contains(index) else { return }
        activeEditor = nil
        withAnimation(ToolbarMetrics.selectorAnimation) {
            palette.setLassoMode(LassoMode.allCases[index])
        }
    }

    private func widthPreviewImage(width: CGFloat, color: UIColor) -> UIImage {
        let size = CGSize(width: 30, height: 24)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let previewWidth = max(13, min(width * 2.0, 26))
            let previewHeight = max(2, min(width, 11))
            let rect = CGRect(
                x: (size.width - previewWidth) / 2,
                y: (size.height - previewHeight) / 2,
                width: previewWidth,
                height: previewHeight
            )
            color.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: previewHeight / 2).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    private func modeSegmentImage(systemName: String, title: String) -> UIImage {
        let size = CGSize(width: 70, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let tint = UIColor.label
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let symbol = UIImage(systemName: systemName, withConfiguration: symbolConfig)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: tint
            ]
            let text = NSString(string: title)
            let textSize = text.size(withAttributes: attrs)
            let iconSize = CGSize(width: 15, height: 15)
            let spacing: CGFloat = 2
            let totalHeight = iconSize.height + spacing + textSize.height
            let startY = max(0, (size.height - totalHeight) / 2)
            let centerX = size.width / 2

            symbol?.draw(in: CGRect(
                x: centerX - iconSize.width / 2,
                y: startY,
                width: iconSize.width,
                height: iconSize.height
            ))
            text.draw(at: CGPoint(
                x: centerX - textSize.width / 2,
                y: startY + iconSize.height + spacing
            ), withAttributes: attrs)
        }.withRenderingMode(.alwaysOriginal)
    }

    private func colorPreviewImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(x: 4, y: 4, width: 20, height: 20)
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.separator.setStroke()
            let outline = UIBezierPath(ovalIn: rect.insetBy(dx: 0.4, dy: 0.4))
            outline.lineWidth = 0.8
            outline.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    private enum SegmentAxis {
        case horizontal
        case vertical
    }

    private func segmentAnchorPoint(index: Int?,
                                    count: Int,
                                    axis: SegmentAxis = .horizontal) -> UnitPoint {
        let safeCount = max(count, 1)
        let clampedIndex = min(max(index ?? 0, 0), safeCount - 1)
        let fraction = (CGFloat(clampedIndex) + 0.5) / CGFloat(safeCount)
        switch axis {
        case .horizontal:
            return UnitPoint(x: fraction, y: 0.5)
        case .vertical:
            return UnitPoint(x: 0.5, y: fraction)
        }
    }

    private func closePropertyEditors() {
        activeEditor = nil
        selectedWidthSlotIndex = nil
        selectedColorSlotIndex = nil
    }

    private var actionGroup: some View {
        HStack(spacing: 4) {
            undoButton
            redoButton
        }
    }

    private var verticalActionGroup: some View {
        VStack(spacing: 4) {
            undoButton
            redoButton
        }
    }

    private var undoButton: some View {
        Button {
            palette.triggerUndo()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.canUndo ? Color.Ink.primary : Color.Ink.tertiary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!palette.canUndo)
        .accessibilityLabel("실행 취소")
    }

    private var redoButton: some View {
        Button {
            palette.triggerRedo()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "arrow.uturn.forward")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.canRedo ? Color.Ink.primary : Color.Ink.tertiary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!palette.canRedo)
        .accessibilityLabel("다시 실행")
    }

    private func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
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

private struct SegmentedPaletteItem {
    var id: String
    var title: String?
    var image: UIImage?
    var verticalSystemImage: String?
    var verticalTitle: String?
    var accessibilityLabel: String

    init(id: String,
         title: String? = nil,
         image: UIImage? = nil,
         verticalSystemImage: String? = nil,
         verticalTitle: String? = nil,
         accessibilityLabel: String) {
        self.id = id
        self.title = title
        self.image = image
        self.verticalSystemImage = verticalSystemImage
        self.verticalTitle = verticalTitle
        self.accessibilityLabel = accessibilityLabel
    }
}

private struct VerticalRetappableSegmentedPicker: UIViewRepresentable {
    var segments: [SegmentedPaletteItem]
    var selectedIndex: Int?
    var accessibilityLabel: String
    var segmentSize: CGSize
    var onSelect: (Int) -> Void
    var onReselect: (Int) -> Void

    private var controlSize: CGSize {
        CGSize(width: segmentSize.height * CGFloat(max(segments.count, 1)),
               height: segmentSize.width)
    }

    private var visualSize: CGSize {
        CGSize(width: segmentSize.width,
               height: segmentSize.height * CGFloat(max(segments.count, 1)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> VerticalSegmentedControlHost {
        let host = VerticalSegmentedControlHost()
        host.control.apportionsSegmentWidthsByContent = false
        host.control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)),
            for: .valueChanged
        )
        host.control.onReselectSegment = { [weak coordinator = context.coordinator] index in
            coordinator?.reselectSegment(at: index)
        }
        configure(host, context: context)
        return host
    }

    func updateUIView(_ host: VerticalSegmentedControlHost, context: Context) {
        context.coordinator.parent = self
        host.control.onReselectSegment = { [weak coordinator = context.coordinator] index in
            coordinator?.reselectSegment(at: index)
        }
        configure(host, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: VerticalSegmentedControlHost,
                      context: Context) -> CGSize? {
        visualSize
    }

    private func configure(_ host: VerticalSegmentedControlHost, context: Context) {
        host.controlSize = controlSize
        host.accessibilityLabel = accessibilityLabel
        host.control.accessibilityLabel = accessibilityLabel

        if host.control.numberOfSegments != segments.count {
            host.control.removeAllSegments()
            for (index, segment) in segments.enumerated() {
                host.control.insertSegment(
                    with: verticalImage(for: segment, traitCollection: host.traitCollection),
                    at: index,
                    animated: false
                )
            }
        } else {
            for (index, segment) in segments.enumerated() {
                host.control.setTitle(nil, forSegmentAt: index)
                host.control.setImage(
                    verticalImage(for: segment, traitCollection: host.traitCollection),
                    forSegmentAt: index
                )
            }
        }

        host.control.selectedSegmentIndex = selectedIndex ?? UISegmentedControl.noSegment
        for (index, segment) in segments.enumerated() {
            host.control.setWidth(segmentSize.height, forSegmentAt: index)
            host.control.setContentPositionAdjustment(.zero, forSegmentType: .any, barMetrics: .default)
            host.control.subviews[safe: index]?.accessibilityLabel = segment.accessibilityLabel
        }
        host.invalidateIntrinsicContentSize()
        host.setNeedsLayout()
    }

    private func verticalImage(for segment: SegmentedPaletteItem,
                               traitCollection: UITraitCollection) -> UIImage? {
        let maxImageSize = CGSize(width: max(16, segmentSize.width - 8),
                                  height: max(16, segmentSize.height - 8))

        if let systemName = segment.verticalSystemImage,
           let title = segment.verticalTitle {
            return UIImage.segmentModeImage(
                systemName: systemName,
                title: title,
                traitCollection: traitCollection
            )
            .fittedForVerticalSegmentControl(maxSize: maxImageSize)
            .rotatedForVerticalSegmentControl()
        }

        if let image = segment.image {
            return image
                .fittedForVerticalSegmentControl(maxSize: maxImageSize)
                .rotatedForVerticalSegmentControl()
        }

        if let title = segment.title {
            return UIImage.segmentTitleImage(title, traitCollection: traitCollection)
                .fittedForVerticalSegmentControl(maxSize: maxImageSize)
                .rotatedForVerticalSegmentControl()
        }

        return nil
    }

    final class Coordinator: NSObject {
        var parent: VerticalRetappableSegmentedPicker

        init(_ parent: VerticalRetappableSegmentedPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: UISegmentedControl) {
            guard parent.segments.indices.contains(sender.selectedSegmentIndex) else { return }
            parent.onSelect(sender.selectedSegmentIndex)
        }

        func reselectSegment(at index: Int) {
            guard parent.segments.indices.contains(index) else { return }
            parent.onReselect(index)
        }
    }
}

private final class VerticalSegmentedControlHost: UIView {
    let control = RetappableSegmentedControl()
    var controlSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        control.clipsToBounds = false
        control.transform = CGAffineTransform(rotationAngle: .pi / 2)
        addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: controlSize.height, height: controlSize.width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        control.bounds = CGRect(origin: .zero, size: controlSize)
        control.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

private extension UIImage {
    func fittedForVerticalSegmentControl(maxSize: CGSize) -> UIImage {
        guard size.width > maxSize.width || size.height > maxSize.height else {
            return self
        }

        let scaleFactor = min(maxSize.width / max(size.width, 1),
                              maxSize.height / max(size.height, 1))
        let newSize = CGSize(width: floor(size.width * scaleFactor),
                             height: floor(size.height * scaleFactor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
        return image.withRenderingMode(renderingMode)
    }

    func rotatedForVerticalSegmentControl() -> UIImage {
        let newSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: newSize, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cgContext.rotate(by: -.pi / 2)
            draw(in: CGRect(x: -size.width / 2,
                            y: -size.height / 2,
                            width: size.width,
                            height: size.height))
        }
        return image.withRenderingMode(renderingMode)
    }

    static func segmentModeImage(systemName: String,
                                 title: String,
                                 traitCollection: UITraitCollection) -> UIImage {
        let textColor = UIColor.label.resolvedColor(with: traitCollection)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let symbol = UIImage(systemName: systemName, withConfiguration: symbolConfig)?
            .withTintColor(textColor, renderingMode: .alwaysOriginal)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: textColor
        ]
        let text = NSString(string: title)
        let textSize = text.size(withAttributes: attributes)
        let iconSize = CGSize(width: 15, height: 15)
        let spacing: CGFloat = 2
        let contentWidth = max(iconSize.width, ceil(textSize.width))
        let contentHeight = iconSize.height + spacing + ceil(textSize.height)
        let size = CGSize(width: max(24, contentWidth + 4),
                          height: max(32, contentHeight + 4))
        let centerX = size.width / 2
        let startY = (size.height - contentHeight) / 2

        return UIGraphicsImageRenderer(size: size).image { _ in
            symbol?.draw(in: CGRect(
                x: centerX - iconSize.width / 2,
                y: startY,
                width: iconSize.width,
                height: iconSize.height
            ))
            text.draw(at: CGPoint(
                x: centerX - textSize.width / 2,
                y: startY + iconSize.height + spacing
            ), withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }

    static func segmentTitleImage(_ title: String,
                                  traitCollection: UITraitCollection) -> UIImage {
        let textColor = UIColor.label.resolvedColor(with: traitCollection)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: textColor
        ]
        let measuredSize = NSString(string: title).size(withAttributes: attributes)
        let size = CGSize(width: ceil(measuredSize.width) + 12,
                          height: max(24, ceil(measuredSize.height) + 6))

        return UIGraphicsImageRenderer(size: size).image { _ in
            NSString(string: title).draw(
                in: CGRect(x: 6,
                           y: (size.height - measuredSize.height) / 2,
                           width: measuredSize.width,
                           height: measuredSize.height),
                withAttributes: attributes
            )
        }.withRenderingMode(.alwaysOriginal)
    }
}

private struct RetappableSegmentedPicker: UIViewRepresentable {
    var segments: [SegmentedPaletteItem]
    var selectedIndex: Int?
    var accessibilityLabel: String
    var onSelect: (Int) -> Void
    var onReselect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> RetappableSegmentedControl {
        let control = RetappableSegmentedControl()
        control.apportionsSegmentWidthsByContent = false
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)),
            for: .valueChanged
        )
        control.onReselectSegment = { [weak coordinator = context.coordinator] index in
            coordinator?.reselectSegment(at: index)
        }
        configure(control)
        return control
    }

    func updateUIView(_ control: RetappableSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.onReselectSegment = { [weak coordinator = context.coordinator] index in
            coordinator?.reselectSegment(at: index)
        }
        configure(control)
    }

    private func configure(_ control: UISegmentedControl) {
        if control.numberOfSegments != segments.count {
            control.removeAllSegments()
            for (index, segment) in segments.enumerated() {
                insert(segment, in: control, at: index)
            }
        } else {
            for (index, segment) in segments.enumerated() {
                if let title = segment.title {
                    control.setTitle(title, forSegmentAt: index)
                    control.setImage(nil, forSegmentAt: index)
                } else {
                    control.setTitle(nil, forSegmentAt: index)
                    control.setImage(segment.image, forSegmentAt: index)
                }
            }
        }

        control.selectedSegmentIndex = selectedIndex ?? UISegmentedControl.noSegment
        control.accessibilityLabel = accessibilityLabel
        for (index, segment) in segments.enumerated() {
            control.setWidth(0, forSegmentAt: index)
            control.setContentPositionAdjustment(.zero, forSegmentType: .any, barMetrics: .default)
            control.subviews[safe: index]?.accessibilityLabel = segment.accessibilityLabel
        }
    }

    private func insert(_ segment: SegmentedPaletteItem, in control: UISegmentedControl, at index: Int) {
        if let title = segment.title {
            control.insertSegment(withTitle: title, at: index, animated: false)
        } else {
            control.insertSegment(with: segment.image, at: index, animated: false)
        }
    }

    final class Coordinator: NSObject {
        var parent: RetappableSegmentedPicker

        init(_ parent: RetappableSegmentedPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: UISegmentedControl) {
            guard parent.segments.indices.contains(sender.selectedSegmentIndex) else { return }
            parent.onSelect(sender.selectedSegmentIndex)
        }

        func reselectSegment(at index: Int) {
            guard parent.segments.indices.contains(index) else { return }
            parent.onReselect(index)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class RetappableSegmentedControl: UISegmentedControl {
    var onReselectSegment: ((Int) -> Void)?
    private var segmentIndexAtTouchStart: Int?
    private var selectedIndexAtTouchStart = UISegmentedControl.noSegment

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            segmentIndexAtTouchStart = segmentIndex(at: touch.location(in: self))
            selectedIndexAtTouchStart = selectedSegmentIndex
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let startedSegment = segmentIndexAtTouchStart
        let startedSelection = selectedIndexAtTouchStart
        let endedSegment = touches.first.map { segmentIndex(at: $0.location(in: self)) } ?? nil

        super.touchesEnded(touches, with: event)

        defer {
            segmentIndexAtTouchStart = nil
            selectedIndexAtTouchStart = UISegmentedControl.noSegment
        }

        guard let startedSegment,
              startedSegment == startedSelection,
              endedSegment == startedSelection else {
            return
        }

        onReselectSegment?(startedSelection)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        segmentIndexAtTouchStart = nil
        selectedIndexAtTouchStart = UISegmentedControl.noSegment
        super.touchesCancelled(touches, with: event)
    }

    private func segmentIndex(at point: CGPoint) -> Int? {
        guard numberOfSegments > 0, bounds.contains(point) else { return nil }
        let segmentWidth = bounds.width / CGFloat(numberOfSegments)
        guard segmentWidth > 0 else { return nil }
        return min(max(Int(point.x / segmentWidth), 0), numberOfSegments - 1)
    }
}

private struct DrawingToolSettingsEditor: View {
    let tool: ToolKind
    let penKind: PenKind
    @Binding var width: CGFloat
    let widthRange: ClosedRange<CGFloat>
    @Binding var color: Color
    let presetColors: [Color]
    let markerSubmode: MarkerSubmode
    let onSelectPenKind: (PenKind) -> Void
    let onSetMarkerSubmode: (MarkerSubmode) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let fineStep: CGFloat = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if tool == .pen {
                penKindSection
            }

            if tool == .marker {
                markerModeSection
            }

            widthSection
            colorSection
        }
        .frame(width: editorWidth)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSystemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Ink.primary)
                .frame(width: 30, height: 30)
                .background(Color.Surface.fill, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .stroke(Color.Rule.hairline, lineWidth: 0.8)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(AppType.bodyEmphasized)
                    .foregroundStyle(Color.Ink.primary)
                Text(formattedWidth)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.Ink.secondary)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Color.Rule.hairline, lineWidth: 0.8))
        }
    }

    private var penKindSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("펜 종류")
            HStack(spacing: 6) {
                ForEach(PenKind.allCases) { kind in
                    Button {
                        onSelectPenKind(kind)
                        UIImpactFeedbackGenerator(style: kind.hapticStyle).impactOccurred()
                    } label: {
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(penKind == kind ? Color.Ink.primary : Color.Ink.secondary)
                            .frame(width: compactLayout ? 42 : 54, height: 32)
                            .background(
                                Color.Surface.fill,
                                in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                    .stroke(penKind == kind ? Color.accentColor : Color.Rule.hairline,
                                            lineWidth: penKind == kind ? 2 : 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.label)
                }
            }
        }
    }

    private var markerModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("형광펜 모드")
            markerModeToggle(title: "잉크 스트로크", systemImage: "scribble", keyPath: \.inkEnabled)
            markerModeToggle(title: "텍스트 하이라이트", systemImage: "highlighter", keyPath: \.highlightEnabled)
            markerModeToggle(title: "영역 선택", systemImage: "rectangle.dashed", keyPath: \.regionEnabled)
        }
    }

    private func markerModeToggle(title: String,
                                  systemImage: String,
                                  keyPath: WritableKeyPath<MarkerSubmode, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { markerSubmode[keyPath: keyPath] },
            set: { newValue in
                var updated = markerSubmode
                updated[keyPath: keyPath] = newValue
                onSetMarkerSubmode(updated)
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14))
            }
            .foregroundStyle(Color.Ink.primary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var widthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("굵기")

            Slider(value: steppedWidth, in: widthRange, step: fineStep)
                .frame(width: editorWidth - 12)

            HStack(spacing: 6) {
                widthStepButton(label: "-1", delta: -1)
                widthStepButton(label: "-0.1", delta: -0.1)
                widthStepButton(label: "+0.1", delta: 0.1)
                widthStepButton(label: "+1", delta: 1)
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("색상")

            HStack(spacing: 8) {
                ForEach(Array(visiblePresetColors.enumerated()), id: \.offset) { _, presetColor in
                    Button {
                        color = presetColor
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Circle()
                            .fill(presetColor)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(isSelected(presetColor) ? Color.accentColor : Color.Rule.hairline,
                                            lineWidth: isSelected(presetColor) ? 2.2 : 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                }

                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34, height: 28)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.Ink.secondary)
    }

    private var steppedWidth: Binding<CGFloat> {
        Binding(
            get: { roundedToFineStep(width) },
            set: { width = clamped(roundedToFineStep($0)) }
        )
    }

    private var formattedWidth: String {
        String(format: "%.1f pt", Double(roundedToFineStep(width)))
    }

    private var headerTitle: String {
        tool == .pen ? penKind.label : tool.label
    }

    private var headerSystemImage: String {
        tool == .pen ? penKind.systemImage : tool.systemImage
    }

    private var compactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private var editorWidth: CGFloat {
        compactLayout ? 228 : 260
    }

    private var visiblePresetColors: [Color] {
        Array(presetColors.prefix(compactLayout ? 4 : 6))
    }

    private var stepButtonWidth: CGFloat {
        compactLayout ? 50 : 58
    }

    private func widthStepButton(label: String, delta: CGFloat) -> some View {
        Button {
            width = clamped(roundedToFineStep(width + delta))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.Ink.primary)
                .frame(width: stepButtonWidth, height: 30)
                .background(Color.Surface.fill, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .stroke(Color.Rule.hairline, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tool.label) 굵기 \(label) pt")
    }

    private func roundedToFineStep(_ value: CGFloat) -> CGFloat {
        (value / fineStep).rounded() * fineStep
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, widthRange.lowerBound), widthRange.upperBound)
    }

    private func isSelected(_ presetColor: Color) -> Bool {
        let current = UIColor(color)
        let preset = UIColor(presetColor)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        current.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        preset.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let tol: CGFloat = 0.005
        return abs(r1 - r2) < tol && abs(g1 - g2) < tol && abs(b1 - b2) < tol
    }
}

private struct WidthSlotEditor: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let color: Color

    private let fineStep: CGFloat = 0.1

    var body: some View {
        VStack(spacing: 12) {
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

                Text(formattedWidth)
                    .font(AppType.bodyEmphasized)
                    .monospacedDigit()
                    .foregroundStyle(Color.Ink.primary)
                    .frame(width: 72, alignment: .leading)
            }

            Slider(value: steppedWidth, in: range, step: fineStep)
                .frame(width: 236)

            HStack(spacing: 6) {
                widthStepButton(label: "-1", delta: -1)
                widthStepButton(label: "-0.1", delta: -0.1)
                widthStepButton(label: "+0.1", delta: 0.1)
                widthStepButton(label: "+1", delta: 1)
            }
        }
        .frame(width: 248)
    }

    private var steppedWidth: Binding<CGFloat> {
        Binding(
            get: { roundedToFineStep(width) },
            set: { width = clamped(roundedToFineStep($0)) }
        )
    }

    private var formattedWidth: String {
        String(format: "%.1f pt", Double(roundedToFineStep(width)))
    }

    private func widthStepButton(label: String, delta: CGFloat) -> some View {
        Button {
            width = clamped(roundedToFineStep(width + delta))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.Ink.primary)
                .frame(width: 54, height: 32)
                .background(Color.Surface.fill, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .stroke(Color.Rule.hairline, lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("굵기 \(label) pt")
    }

    private func roundedToFineStep(_ value: CGFloat) -> CGFloat {
        (value / fineStep).rounded() * fineStep
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
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
