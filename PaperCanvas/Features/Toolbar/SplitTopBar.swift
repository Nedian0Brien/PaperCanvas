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
    let activeNotePaperID: UUID?
    let activeCanvasPaperID: UUID?
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
    var onCreateDocument: (PaperDocumentKind) -> Void = { _ in }

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
    }

    /// Canonical iOS 26 Liquid Glass morph: both states live inside the same
    /// `GlassEffectContainer` and share a `glassEffectID`. The container animates
    /// the glass material flowing between the capsule and the expanded panel
    /// when `documentSwitcherKind` toggles under a `withAnimation` transaction.
    @ViewBuilder
    private func expandedPanel(for kind: PaperDocumentKind) -> some View {
        DocumentSwitcherPanel(
            selectedKind: kind,
            documents: documents,
            activePaperID: kind == .note ? activeNotePaperID : activeCanvasPaperID,
            onSelectDocument: onSelectDocument,
            onCreateDocument: { onCreateDocument(kind) }
        )
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
        Group {
            if documentSwitcherKind == .note {
                expandedPanel(for: .note)
                    .glassEffect(.regular.interactive(),
                                 in: .rect(cornerRadius: Radius.xl))
                    .glassEffectID(DocumentSwitcherGlassID.note,
                                   in: documentSwitcherNamespace)
            } else {
                noteIdentityContent
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID(DocumentSwitcherGlassID.note,
                                   in: documentSwitcherNamespace)
            }
        }
        .layoutPriority(2)
    }

    @ViewBuilder
    private var noteIdentityContent: some View {
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
    }

    // MARK: - Trailing: canvas identity

    @ViewBuilder
    private var trailingCluster: some View {
        Group {
            if documentSwitcherKind == .canvas {
                expandedPanel(for: .canvas)
                    .glassEffect(.regular.interactive(),
                                 in: .rect(cornerRadius: Radius.xl))
                    .glassEffectID(DocumentSwitcherGlassID.canvas,
                                   in: documentSwitcherNamespace)
            } else {
                trailingClusterContent
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID(DocumentSwitcherGlassID.canvas,
                                   in: documentSwitcherNamespace)
            }
        }
        .layoutPriority(2)
    }

    @ViewBuilder
    private var trailingClusterContent: some View {
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
    let activePaperID: UUID?
    let onSelectDocument: (PaperDocument) -> Void
    let onCreateDocument: () -> Void

    @State private var hasAppeared = false

    private var visibleDocuments: [PaperDocument] {
        documents.filter { $0.documentKind == selectedKind }
    }

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.s),
        GridItem(.flexible(), spacing: Spacing.s)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Spacer()
                createPill
            }
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.m)

            if visibleDocuments.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.s) {
                        ForEach(visibleDocuments) { document in
                            Button {
                                onSelectDocument(document)
                            } label: {
                                DocumentSwitcherCard(
                                    document: document,
                                    isActive: document.id == activePaperID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.m)
                }
            }
        }
        .frame(width: 420)
        .frame(maxHeight: 540)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.97, anchor: .top)
        .onAppear {
            withAnimation(Motion.morphContent.delay(0.06)) {
                hasAppeared = true
            }
        }
    }

    private var createPill: some View {
        Button(action: onCreateDocument) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text(selectedKind == .note ? "새 노트" : "새 캔버스")
            }
            .font(AppType.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.AccentTokens.primary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedKind == .note ? "새 노트 추가" : "새 캔버스 추가")
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: selectedKind.systemImage)
                .font(.system(size: 32))
                .foregroundStyle(Color.Ink.tertiary)
            Text(selectedKind == .note ? "노트가 없습니다" : "캔버스가 없습니다")
                .font(AppType.callout)
                .foregroundStyle(Color.Ink.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.bottom, Spacing.m)
    }
}

private struct DocumentSwitcherCard: View {
    let document: PaperDocument
    let isActive: Bool

    @State private var thumbnail: UIImage?

    private var thumbnailKey: String {
        "\(document.id.uuidString)-\(document.updatedAt.timeIntervalSince1970)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                } else {
                    Image(systemName: document.documentKind.systemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(Color.Ink.tertiary)
                }
            }
            .frame(height: 140)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .strokeBorder(isActive ? Color.AccentTokens.primary : Color.Rule.hairline,
                                  lineWidth: isActive ? 2 : 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(AppType.callout)
                    .foregroundStyle(Color.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(document.updatedAt, format: .relative(presentation: .named))
                    .font(AppType.caption)
                    .foregroundStyle(Color.Ink.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 4)
        .contentShape(.rect)
        .task(id: thumbnailKey) {
            thumbnail = PaperThumbnailService.shared.thumbnail(for: document)
            if thumbnail == nil {
                await PaperThumbnailService.shared.generateIfNeeded(for: document)
                thumbnail = PaperThumbnailService.shared.thumbnail(for: document)
            }
        }
    }
}

