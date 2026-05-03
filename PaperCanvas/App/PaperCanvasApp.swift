import SwiftUI
import SwiftData

@main
struct PaperCanvasApp: App {
    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
        .modelContainer(for: [PaperDocument.self, ScrapItem.self, PageInk.self])
    }
}
