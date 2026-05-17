import SwiftUI
import SwiftData

@main
struct PaperCanvasApp: App {
    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
        .modelContainer(for: [PaperDocument.self, PaperFolder.self, ScrapItem.self, PageInk.self, PDFTextHighlight.self, PDFRegionMark.self])
    }
}
