import SwiftUI

struct PaletteToolbar: View {
    @Bindable var palette: PaletteState
    @State private var editingPreset: PresetEditTarget?

    var body: some View {
        HStack(spacing: 12) {
            toolGroup
            divider
            widthGroup
                .opacity(palette.tool.supportsWidth ? 1 : 0.4)
                .disabled(!palette.tool.supportsWidth)
            divider
            colorGroup
            Spacer(minLength: 0)
            divider
            actionGroup
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
        .sheet(item: $editingPreset) { target in
            PresetColorEditor(
                index: target.index,
                color: palette.presetColors[target.index],
                onCommit: { newColor in
                    palette.setPresetColor(newColor, atIndex: target.index)
                    editingPreset = nil
                },
                onCancel: { editingPreset = nil }
            )
            .presentationDetents([.height(280)])
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 0.5, height: 28)
    }

    private var toolGroup: some View {
        HStack(spacing: 4) {
            ForEach(ToolKind.allCases) { kind in
                Button {
                    let shouldHaptic = palette.tool != kind
                    palette.tool = kind
                    if shouldHaptic {
                        UIImpactFeedbackGenerator(style: kind.hapticStyle).impactOccurred()
                    }
                } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(palette.tool == kind ? Color.accentColor : Color.primary)
                        .background(
                            palette.tool == kind ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: .rect(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.label)
            }
        }
    }

    private var widthGroup: some View {
        HStack(spacing: 8) {
            Image(systemName: "scribble.variable")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { palette.width },
                    set: { palette.setWidth($0) }
                ),
                in: palette.tool.widthRange
            )
            .frame(width: 110)
            Menu {
                ForEach(palette.tool.widthSteps, id: \.self) { step in
                    Button {
                        palette.setWidth(step)
                    } label: {
                        Label("\(Int(step)) pt", systemImage: stepIcon(for: step))
                    }
                }
            } label: {
                previewDot
            }
        }
    }

    private func stepIcon(for step: CGFloat) -> String {
        switch step {
        case ..<5:    return "circle.fill"
        case ..<15:   return "circle.circle.fill"
        default:      return "circle.dashed.inset.filled"
        }
    }

    private var previewDot: some View {
        let dotSize = max(4, min(palette.width, 28))
        let fillColor: Color = (palette.tool == .eraser) ? Color(.systemGray3) : palette.color
        return ZStack {
            Circle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 32, height: 32)
            Circle()
                .fill(fillColor)
                .frame(width: dotSize, height: dotSize)
        }
    }

    private var colorGroup: some View {
        HStack(spacing: 6) {
            ForEach(Array(palette.presetColors.enumerated()), id: \.offset) { index, color in
                colorButton(color, atIndex: index)
            }
            ColorPicker("", selection: $palette.color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28, height: 28)
                .opacity(palette.tool.supportsColor ? 1.0 : 0.4)
                .disabled(!palette.tool.supportsColor)
        }
    }

    private func colorButton(_ color: Color, atIndex index: Int) -> some View {
        let isSelected = palette.tool.supportsColor && colorsApproximatelyEqual(palette.color, color)
        return Button {
            palette.color = color
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 22, height: 22)
                Circle()
                    .stroke(isSelected ? Color.primary : Color(.separator),
                            lineWidth: isSelected ? 2.5 : 1)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .opacity(palette.tool.supportsColor ? 1.0 : 0.4)
        .disabled(!palette.tool.supportsColor)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    editingPreset = PresetEditTarget(index: index)
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
                    .foregroundStyle(palette.canUndo ? Color.primary : Color(.tertiaryLabel))
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
                    .foregroundStyle(palette.canRedo ? Color.primary : Color(.tertiaryLabel))
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

private struct PresetEditTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct PresetColorEditor: View {
    let index: Int
    @State var color: Color
    let onCommit: (Color) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ColorPicker("프리셋 #\(index + 1) 색상",
                            selection: $color,
                            supportsOpacity: false)
                    .padding(.horizontal)

                Circle()
                    .fill(color)
                    .frame(width: 96, height: 96)
                    .overlay(Circle().stroke(Color(.separator)))

                Spacer()
            }
            .padding(.top, 16)
            .navigationTitle("색 슬롯 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") { onCommit(color) }
                        .bold()
                }
            }
        }
    }
}
