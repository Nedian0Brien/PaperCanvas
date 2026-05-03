import Foundation
import SwiftData

@Model
final class PageInk {
    @Attribute(.unique) var id: UUID
    var pageIndex: Int
    @Attribute(.externalStorage) var drawingData: Data
    var updatedAt: Date

    var document: PaperDocument?

    init(pageIndex: Int, drawingData: Data) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.drawingData = drawingData
        self.updatedAt = .now
    }
}
