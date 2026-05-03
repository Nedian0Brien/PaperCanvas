import SwiftUI
import PencilKit

struct CanvasView: View {
    @Binding var drawing: PKDrawing
    @Binding var contentOffset: CGPoint
    @Binding var resetTrigger: UUID?
    let initialContentSize: CGSize
    let scraps: [ScrapItem]
    let palette: PaletteState
    var background: CanvasBackground = .dots
    var onScrapTap: ((UUID) -> Void)? = nil
    var onDrop: ((CanvasDropPayload) -> Void)? = nil
    var onScrapMoved: ((UUID, CGPoint) -> Void)? = nil
    var onScrapResized: ((UUID, CGSize) -> Void)? = nil
    var onScrapDeleted: ((UUID) -> Void)? = nil

    var body: some View {
        ZStack {
            Color(.systemBackground)
            InfiniteCanvasContainer(drawing: $drawing,
                                    contentOffset: $contentOffset,
                                    resetTrigger: $resetTrigger,
                                    initialContentSize: initialContentSize,
                                    scraps: scraps,
                                    tool: palette.pkTool,
                                    undoTrigger: palette.undoTrigger,
                                    redoTrigger: palette.redoTrigger,
                                    isMainCanvasActive: palette.lastActiveCanvas == .main,
                                    background: background,
                                    onScrapTap: onScrapTap,
                                    onDrop: onDrop,
                                    onScrapMoved: onScrapMoved,
                                    onScrapResized: onScrapResized,
                                    onScrapDeleted: onScrapDeleted,
                                    onUndoRedoStateChanged: { canUndo, canRedo in
                                        palette.mainCanUndo = canUndo
                                        palette.mainCanRedo = canRedo
                                    },
                                    onMainCanvasActivated: {
                                        palette.lastActiveCanvas = .main
                                    },
                                    onPencilTap: {
                                        palette.switchToPreviousTool()
                                    })
        }
    }
}
