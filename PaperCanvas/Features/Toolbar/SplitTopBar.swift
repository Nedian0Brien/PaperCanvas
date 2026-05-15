import SwiftUI

private enum DocumentSwitcherGlassID: Hashable, Sendable {
    case note
    case canvas

    init(kind: PaperDocumentKind) {
        switch kind {
        case .note:   self = .note
        case .canvas: self = .canvas
        }
    }
}

struct SplitTopBar: View {
    let noteTitle: String
    let canvasTitle: String
    let activePaperID: UUID
    let documents: [PaperDocument]
    var documentSwitcherKind: PaperDocumentKind?

    var pageIndex: Int = 0
    var totalPages: Int = 0
    var canvasZoom: CGFloat = 1.0

    let onLibraryTap: () -> Void
    var onPageJumpTap: () -> Void = {}
    var onZoomReset: () -> Void = {}
    var onRecenterCanvas: () -> Void = {}
    var onAddTextNote: () -> Void = {}
    var onToggleDocumentSwitcher: (PaperDocumentKind) -> Void = { _ in }
    var onSelectDocument: (PaperDocument) -> Void = { _ in }

    var canvasBackground: CanvasBackground = .dots
    var onPickCanvasBackground: (CanvasBackground) -> Void = { _ in }

    var debugActions: DebugActions?

    struct DebugActions {
        let addTextScrap: () -> Void
        let addImageScrap: () -> Void
    }

    private var hasPDF: Bool { totalPages > 0 }

    @Namespace private var documentSwitcherNamespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                leadingCluster
                Spacer(minLength: 0)
                trailingCluster
            }
        }
        .frame(maxWidth: .infinity, minHeight: TopBarMetrics.barHeight)
        .animation(Motion.indirectFast, value: documentSwitcherKind)
    }

    /// Identity used to morph the title capsule into the expanded switcher panel
    /// in the same `GlassEffectContainer`. The capsule emits `kind` while collapsed
    /// and `nil` while expanded; the panel emits `kind`. The Liquid Glass system
    /// matches the two and animates a single element between the two shapes.
    private func capsuleGlassID(for kind: PaperDocumentKind) -> DocumentSwitcherGlassID? {
        documentSwitcherKind == kind ? nil : DocumentSwitcherGlassID(kind: kind)
    }

    @ViewBuilder
    private func morphedPanel(for kind: PaperDocumentKind) -> some View {
        DocumentSwitcherPanel(
            selectedKind: kind,
            documents: documents,
            activePaperID: activePaperID,
            onSelectDocument: onSelectDocument
        )
        .glassEffect(.regular.interactive(),
                     in: .rect(cornerRadius: Radius.xl))
        .glassEffectID(DocumentSwitcherGlassID(kind: kind),
                       in: documentSwitcherNamespace)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .scale(scale: 0.98))
        ))
    }

    // MARK: - Leading: library + note identity

    @ViewBuilder
    private var leadingCluster: some View {
        HStack(spacing: 8) {
            Button(action: onLibraryTap) {
                Image(systemName: "books.vertical")
                    .font(AppType.toolGlyph)
                    .frame(width: TopBarMetrics.buttonSize,
                           height: TopBarMetrics.buttonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("라이브러리")

            noteIdentity
        }
    }

    @ViewBuilder
    private var noteIdentity: some View {
        HStack(spacing: 4) {
            Button {
                onToggleDocumentSwitcher(.note)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: PaperDocumentKind.note.systemImage)
                        .font(AppType.toolGlyph)
                        .foregroundStyle(Color.Ink.secondary)
                        .frame(width: 32, height: TopBarMetrics.buttonSize)

                    Text(noteTitle)
                        .font(AppType.bodyEmphasized)
                        .foregroundStyle(Color.Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 240, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.Ink.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("노트 선택기")

            if hasPDF {
                divider
                Button(action: onPageJumpTap) {
                    Text("\(pageIndex + 1) / \(totalPages)")
                        .font(AppType.monoCaption)
                        .foregroundStyle(Color.Ink.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("페이지 \(pageIndex + 1) / \(totalPages), 탭하여 점프")
            }

            divider

            Menu {
                Section("PDF") {
                    Button("페이지 점프...", action: onPageJumpTap).disabled(!hasPDF)
                }
                if let debugActions {
                    Section("디버그") {
                        Button("텍스트 스크랩 추가", action: debugActions.addTextScrap)
                        Button("이미지 스크랩 추가", action: debugActions.addImageScrap)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppType.toolGlyph)
                    .frame(width: TopBarMetrics.buttonSize,
                           height: TopBarMetrics.buttonSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("PDF 메뉴")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(minHeight: TopBarMetrics.buttonSize)
        .opacity(documentSwitcherKind == .note ? 0 : 1)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(capsuleGlassID(for: .note), in: documentSwitcherNamespace)
        .overlay(alignment: .topLeading) {
            if documentSwitcherKind == .note {
                morphedPanel(for: .note)
                    .fixedSize()
            }
        }
        .layoutPriority(2)
    }

    // MARK: - Trailing: canvas identity

    @ViewBuilder
    private var trailingCluster: some View {
        HStack(spacing: 4) {
            Button {
                onToggleDocumentSwitcher(.canvas)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: PaperDocumentKind.canvas.systemImage)
                        .font(AppType.toolGlyph)
                        .foregroundStyle(Color.Ink.secondary)
                        .frame(width: 32, height: TopBarMetrics.buttonSize)

                    Text(canvasTitle)
                        .font(AppType.bodyEmphasized)
                        .foregroundStyle(Color.Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 240, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.Ink.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("캔버스 선택기")

            divider

            Button(action: onZoomReset) {
                Text("\(Int((canvasZoom * 100).rounded()))%")
                    .font(AppType.monoCaption)
                    .foregroundStyle(Color.Ink.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("줌 \(Int((canvasZoom * 100).rounded()))%, 탭하여 1:1")

            divider

            Menu {
                Section("캔버스") {
                    Button(action: onAddTextNote) {
                        Label("텍스트 메모 추가", systemImage: "square.and.pencil")
                    }
                    Button("캔버스 가운데로", action: onRecenterCanvas)
                }
                Section("배경") {
                    ForEach(CanvasBackground.allCases) { type in
                        Button {
                            onPickCanvasBackground(type)
                        } label: {
                            Label(type.label, systemImage: type.systemImage)
                            if canvasBackground == type {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppType.toolGlyph)
                    .frame(width: TopBarMetrics.buttonSize,
                           height: TopBarMetrics.buttonSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("캔버스 메뉴")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .frame(minHeight: TopBarMetrics.buttonSize)
        .opacity(documentSwitcherKind == .canvas ? 0 : 1)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(capsuleGlassID(for: .canvas), in: documentSwitcherNamespace)
        .overlay(alignment: .topTrailing) {
            if documentSwitcherKind == .canvas {
                morphedPanel(for: .canvas)
                    .fixedSize()
            }
        }
        .layoutPriority(2)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.Rule.hairline)
            .frame(width: 1, height: 18)
    }
}

private struct DocumentSwitcherPanel: View {
    let selectedKind: PaperDocumentKind
    let documents: [PaperDocument]
    let activePaperID: UUID
    let onSelectDocument: (PaperDocument) -> Void

    private var visibleDocuments: [PaperDocument] {
        documents.filter { $0.documentKind == selectedKind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if visibleDocuments.isEmpty {
                Label(emptyText, systemImage: selectedKind.systemImage)
                    .font(AppType.callout)
                    .foregroundStyle(Color.Ink.secondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleDocuments) { document in
                            Button {
                                onSelectDocument(document)
                            } label: {
                                DocumentSwitcherRow(
                                    document: document,
                                    isActive: document.id == activePaperID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(Spacing.m)
        .frame(width: 360)
    }

    private var emptyText: String {
        switch selectedKind {
        case .note:
            return "선택할 노트가 없습니다"
        case .canvas:
            return "선택할 캔버스가 없습니다"
        }
    }

}

private struct DocumentSwitcherRow: View {
    let document: PaperDocument
    let isActive: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: document.documentKind.systemImage)
                .font(AppType.toolGlyph)
                .foregroundStyle(isActive ? Color.AccentTokens.primary : Color.Ink.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(AppType.callout)
                    .foregroundStyle(Color.Ink.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(document.documentKind.label)
                    if let folderName = document.folder?.name {
                        Text("·")
                        Text(folderName)
                    }
                    Text("·")
                    Text(document.updatedAt, format: .relative(presentation: .named))
                }
                .font(AppType.caption)
                .foregroundStyle(Color.Ink.secondary)
                .lineLimit(1)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.AccentTokens.primary)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 8)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: Radius.m)
                    .fill(Color.AccentTokens.tint)
            }
        }
        .contentShape(.rect)
    }
}
