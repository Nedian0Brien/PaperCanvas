import Foundation
import SwiftData

@Model
final class PaperDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var bookmarkData: Data?
    var sourceURLString: String?
    var lastPageIndex: Int
    var canvasOffsetX: Double
    var canvasOffsetY: Double
    var canvasContentWidth: Double
    var canvasContentHeight: Double
    var drawingData: Data?
    var pdfInkData: Data?
    var canvasBackgroundRaw: String = "dots"
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ScrapItem.document)
    var scrapItems: [ScrapItem] = []

    @Relationship(deleteRule: .cascade, inverse: \PageInk.document)
    var pageInks: [PageInk] = []

    init(title: String,
         bookmarkData: Data? = nil,
         sourceURLString: String? = nil) {
        self.id = UUID()
        self.title = title
        self.bookmarkData = bookmarkData
        self.sourceURLString = sourceURLString
        self.lastPageIndex = 0
        self.canvasOffsetX = 0
        self.canvasOffsetY = 0
        self.canvasContentWidth = 4000
        self.canvasContentHeight = 4000
        self.drawingData = nil
        self.pdfInkData = nil
        self.canvasBackgroundRaw = "dots"
        self.createdAt = .now
        self.updatedAt = .now
    }
}
