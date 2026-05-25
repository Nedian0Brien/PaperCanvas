import SwiftUI
import PencilKit
import UIKit

/// Vertical, page-based scrollable note editor for blank (non-PDF) notes.
///
/// Pages are stacked top-to-bottom with a configurable rule pattern drawn
/// behind a single PKCanvasView that spans the full content height. Persisting
/// strokes as one PKDrawing keeps the storage path identical to the existing
/// canvas pane and avoids splitting/joining strokes when pages are added.
struct PageNoteView: View {
    @Binding var drawing: PKDrawing
    let pageStyle: NotePageStyle
    let pageCount: Int
    let pageSize: CGSize
    let palette: PaletteState

    var onPageNoteActivated: (() -> Void)? = nil
    var onStrokeBegan: (() -> Void)? = nil
    var onStrokeEnded: (() -> Void)? = nil
    var onPencilTap: (() -> Void)? = nil
    var onAddPageRequested: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PageNoteScrollView(
                drawing: $drawing,
                pageStyle: pageStyle,
                pageCount: pageCount,
                pageSize: pageSize,
                tool: palette.pkTool,
                toolKind: palette.tool,
                isMarkupActive: palette.lastActiveCanvas == .pdfInk,
                undoTrigger: palette.undoTrigger,
                redoTrigger: palette.redoTrigger,
                onActivated: {
                    palette.lastActiveCanvas = .pdfInk
                    onPageNoteActivated?()
                },
                onStrokeBegan: onStrokeBegan,
                onStrokeEnded: onStrokeEnded,
                onPencilTap: onPencilTap,
                onUndoRedoStateChanged: { canUndo, canRedo in
                    palette.pdfCanUndo = canUndo
                    palette.pdfCanRedo = canRedo
                }
            )

            if let onAddPageRequested {
                Button(action: onAddPageRequested) {
                    Label("페이지 추가", systemImage: "plus.rectangle.on.rectangle")
                        .font(AppType.callout.weight(.semibold))
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                }
                .buttonStyle(.borderedProminent)
                .chromeGlassCapsule()
                .padding(Spacing.l)
                .accessibilityLabel("페이지 추가")
            }
        }
    }
}

// MARK: - UIScrollView host

private struct PageNoteScrollView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let pageStyle: NotePageStyle
    let pageCount: Int
    let pageSize: CGSize
    let tool: PKTool
    let toolKind: ToolKind
    let isMarkupActive: Bool
    let undoTrigger: UUID?
    let redoTrigger: UUID?
    let onActivated: () -> Void
    let onStrokeBegan: (() -> Void)?
    let onStrokeEnded: (() -> Void)?
    let onPencilTap: (() -> Void)?
    let onUndoRedoStateChanged: (Bool, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let host = PageNoteHostView()
        host.backgroundColor = .secondarySystemBackground
        context.coordinator.host = host
        context.coordinator.configureInitial(drawing: drawing)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyLayout(pageStyle: pageStyle,
                                        pageCount: pageCount,
                                        pageSize: pageSize)
        context.coordinator.applyTool(tool, kind: toolKind)
        context.coordinator.applyDrawingIfNeeded(drawing)
        context.coordinator.applyUndoRedoTriggers(undo: undoTrigger, redo: redoTrigger)
        if isMarkupActive { context.coordinator.makeFirstResponderIfNeeded() }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIPencilInteractionDelegate {
        var parent: PageNoteScrollView
        weak var host: PageNoteHostView?
        var scrollView: UIScrollView!
        var canvas: PKCanvasView!
        var patternView: PageNotePatternView!
        private var lastAppliedDrawingData: Data?
        private var lastUndoID: UUID?
        private var lastRedoID: UUID?
        private var hasConfigured = false
        private var suppressDrawingPropagation = false
        private var toolPicker: PKToolPicker?

        init(_ parent: PageNoteScrollView) {
            self.parent = parent
        }

        func configureInitial(drawing: PKDrawing) {
            guard let host else { return }
            let scrollView = UIScrollView()
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.backgroundColor = .secondarySystemBackground
            scrollView.alwaysBounceVertical = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.minimumZoomScale = 0.5
            scrollView.maximumZoomScale = 4
            scrollView.delegate = self
            scrollView.contentInsetAdjustmentBehavior = .always

            let content = UIView()
            content.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(content)

            let patternView = PageNotePatternView()
            patternView.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(patternView)

            let canvas = PKCanvasView()
            canvas.translatesAutoresizingMaskIntoConstraints = false
            #if targetEnvironment(simulator)
            canvas.drawingPolicy = .anyInput
            #else
            canvas.drawingPolicy = .pencilOnly
            #endif
            canvas.isScrollEnabled = false
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.delegate = self
            canvas.drawing = drawing
            canvas.tool = parent.tool
            content.addSubview(canvas)

            host.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: host.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])

            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = self
            canvas.addInteraction(pencilInteraction)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(tap)

            self.scrollView = scrollView
            self.canvas = canvas
            self.patternView = patternView
            host.scrollView = scrollView
            host.content = content
            host.canvas = canvas
            host.patternView = patternView

            self.hasConfigured = true
            self.lastAppliedDrawingData = drawing.dataRepresentation()
            applyLayout(pageStyle: parent.pageStyle,
                        pageCount: parent.pageCount,
                        pageSize: parent.pageSize)
        }

        func applyLayout(pageStyle: NotePageStyle,
                         pageCount: Int,
                         pageSize: CGSize) {
            guard hasConfigured, let host, let content = host.content else { return }
            let count = max(1, pageCount)
            let gap: CGFloat = 24
            let totalHeight = pageSize.height * CGFloat(count) + gap * CGFloat(count - 1)
            let contentSize = CGSize(width: pageSize.width, height: totalHeight)

            host.pageStyle = pageStyle
            host.pageCount = count
            host.pageSize = pageSize
            host.pageGap = gap
            patternView.configure(style: pageStyle,
                                  pageSize: pageSize,
                                  pageCount: count,
                                  gap: gap)

            content.frame = CGRect(origin: .zero, size: contentSize)
            patternView.frame = CGRect(origin: .zero, size: contentSize)
            canvas.frame = CGRect(origin: .zero, size: contentSize)
            scrollView.contentSize = contentSize
            host.applyContentInsetForCentering()
        }

        func applyTool(_ tool: PKTool, kind: ToolKind) {
            canvas.tool = tool
            canvas.drawingGestureRecognizer.isEnabled = true
            canvas.isUserInteractionEnabled = true
        }

        func applyDrawingIfNeeded(_ drawing: PKDrawing) {
            let data = drawing.dataRepresentation()
            if data == lastAppliedDrawingData { return }
            lastAppliedDrawingData = data
            suppressDrawingPropagation = true
            canvas.drawing = drawing
            suppressDrawingPropagation = false
        }

        func applyUndoRedoTriggers(undo: UUID?, redo: UUID?) {
            if let undo, undo != lastUndoID {
                lastUndoID = undo
                canvas.undoManager?.undo()
            }
            if let redo, redo != lastRedoID {
                lastRedoID = redo
                canvas.undoManager?.redo()
            }
        }

        func makeFirstResponderIfNeeded() {
            guard canvas.window != nil, !canvas.isFirstResponder else { return }
            canvas.becomeFirstResponder()
            attachToolPickerIfNeeded()
        }

        private func attachToolPickerIfNeeded() {
            if toolPicker == nil {
                toolPicker = PKToolPicker()
            }
            // We rely on the custom palette, so keep the system tool picker
            // hidden — but still register so PencilKit features like the
            // editor's gesture state remain consistent.
            toolPicker?.setVisible(false, forFirstResponder: canvas)
        }

        @objc private func handleTap() {
            parent.onActivated()
            makeFirstResponderIfNeeded()
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !suppressDrawingPropagation else { return }
            let data = canvasView.drawing.dataRepresentation()
            lastAppliedDrawingData = data
            DispatchQueue.main.async { [parent] in
                parent.drawing = canvasView.drawing
                parent.onUndoRedoStateChanged(canvasView.undoManager?.canUndo ?? false,
                                              canvasView.undoManager?.canRedo ?? false)
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.onStrokeBegan?()
            parent.onActivated()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            parent.onStrokeEnded?()
        }

        // MARK: UIScrollViewDelegate (zoom)

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            host?.content
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            host?.applyContentInsetForCentering()
        }

        // MARK: UIPencilInteractionDelegate

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            parent.onPencilTap?()
        }
    }
}

// MARK: - Host view (handles centering when content is narrower than scrollview)

@MainActor
final class PageNoteHostView: UIView {
    weak var scrollView: UIScrollView?
    weak var content: UIView?
    weak var canvas: PKCanvasView?
    weak var patternView: PageNotePatternView?

    var pageStyle: NotePageStyle = .lined
    var pageCount: Int = 1
    var pageSize: CGSize = NotePageStyle.defaultPageSize
    var pageGap: CGFloat = 24

    override func layoutSubviews() {
        super.layoutSubviews()
        applyContentInsetForCentering()
    }

    /// Center the page horizontally when the scroll view is wider than the
    /// page, and add a small top/bottom inset so the user can scroll past the
    /// edges comfortably.
    func applyContentInsetForCentering() {
        guard let scrollView, let content else { return }
        let zoomedWidth = content.frame.width * scrollView.zoomScale
        let zoomedHeight = content.frame.height * scrollView.zoomScale
        let horizontal = max(0, (scrollView.bounds.width - zoomedWidth) / 2)
        let vertical = max(32, (scrollView.bounds.height - zoomedHeight) / 2)
        scrollView.contentInset = UIEdgeInsets(top: max(32, vertical * 0.5),
                                               left: horizontal,
                                               bottom: max(64, vertical * 0.5),
                                               right: horizontal)
    }
}

// MARK: - Pattern background

@MainActor
final class PageNotePatternView: UIView {
    private var pageStyle: NotePageStyle = .lined
    private var pageSize: CGSize = NotePageStyle.defaultPageSize
    private var pageCount: Int = 1
    private var pageGap: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(style: NotePageStyle,
                   pageSize: CGSize,
                   pageCount: Int,
                   gap: CGFloat) {
        self.pageStyle = style
        self.pageSize = pageSize
        self.pageCount = pageCount
        self.pageGap = gap
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // Gap fill (matches scroll view background).
        UIColor.secondarySystemBackground.setFill()
        ctx.fill(rect)

        for index in 0..<pageCount {
            let origin = CGPoint(x: 0,
                                 y: CGFloat(index) * (pageSize.height + pageGap))
            let pageRect = CGRect(origin: origin, size: pageSize)
            guard pageRect.intersects(rect) else { continue }

            // Subtle page shadow
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2),
                          blur: 6,
                          color: UIColor.black.withAlphaComponent(0.18).cgColor)
            UIColor.systemBackground.setFill()
            UIBezierPath(roundedRect: pageRect, cornerRadius: 2).fill()
            ctx.restoreGState()

            // Rulings
            ctx.saveGState()
            ctx.clip(to: pageRect)
            pageStyle.drawBackground(in: pageRect, context: ctx)
            ctx.restoreGState()

            // Page number badge (faded)
            let label = "\(index + 1)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            str.draw(at: CGPoint(x: pageRect.maxX - size.width - 16,
                                 y: pageRect.maxY - size.height - 12))
        }
    }
}
