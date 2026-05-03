import Foundation
import SwiftData

enum ScrapKind: String, Codable {
    case text
    case image
}

@Model
final class ScrapItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var text: String?
    var imageData: Data?
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var sourcePageIndex: Int
    var sourceRectX: Double
    var sourceRectY: Double
    var sourceRectW: Double
    var sourceRectH: Double
    var createdAt: Date

    var document: PaperDocument?

    var kind: ScrapKind {
        get { ScrapKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: ScrapKind,
         text: String? = nil,
         imageData: Data? = nil,
         position: CGPoint,
         size: CGSize,
         sourcePageIndex: Int,
         sourceRect: CGRect) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.text = text
        self.imageData = imageData
        self.positionX = position.x
        self.positionY = position.y
        self.width = size.width
        self.height = size.height
        self.sourcePageIndex = sourcePageIndex
        self.sourceRectX = sourceRect.origin.x
        self.sourceRectY = sourceRect.origin.y
        self.sourceRectW = sourceRect.width
        self.sourceRectH = sourceRect.height
        self.createdAt = .now
    }
}
