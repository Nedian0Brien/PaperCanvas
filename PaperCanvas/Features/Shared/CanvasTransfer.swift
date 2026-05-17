import Foundation
import CoreGraphics

struct PDFNavigationTarget: Equatable, Identifiable {
    let id: UUID
    let pageIndex: Int
    let pageRect: CGRect

    init(pageIndex: Int, pageRect: CGRect) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.pageRect = pageRect
    }
}

final class TextScrapPayload: NSObject {
    let text: String
    let pageIndex: Int
    let pageBounds: CGRect

    init(text: String, pageIndex: Int, pageBounds: CGRect) {
        self.text = text
        self.pageIndex = pageIndex
        self.pageBounds = pageBounds
    }
}

final class ImageScrapPayload: NSObject {
    let imageData: Data
    let pageIndex: Int
    let pageBounds: CGRect

    init(imageData: Data, pageIndex: Int, pageBounds: CGRect) {
        self.imageData = imageData
        self.pageIndex = pageIndex
        self.pageBounds = pageBounds
    }
}

struct CanvasDropPayload {
    let kind: ScrapKind
    let text: String?
    let imageData: Data?
    let position: CGPoint
    let sourcePageIndex: Int
    let sourceRect: CGRect
    let anchorKind: PDFAnchorKind?
    let anchorID: UUID?

    init(kind: ScrapKind,
         text: String?,
         imageData: Data?,
         position: CGPoint,
         sourcePageIndex: Int,
         sourceRect: CGRect,
         anchorKind: PDFAnchorKind? = nil,
         anchorID: UUID? = nil) {
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.position = position
        self.sourcePageIndex = sourcePageIndex
        self.sourceRect = sourceRect
        self.anchorKind = anchorKind
        self.anchorID = anchorID
    }
}

final class AnchorDragPayload: NSObject {
    let anchorKind: PDFAnchorKind
    let anchorID: UUID
    let scrapKind: ScrapKind
    let text: String?
    let imageData: Data?
    let pageIndex: Int
    let pageRect: CGRect

    init(anchorKind: PDFAnchorKind,
         anchorID: UUID,
         scrapKind: ScrapKind,
         text: String?,
         imageData: Data?,
         pageIndex: Int,
         pageRect: CGRect) {
        self.anchorKind = anchorKind
        self.anchorID = anchorID
        self.scrapKind = scrapKind
        self.text = text
        self.imageData = imageData
        self.pageIndex = pageIndex
        self.pageRect = pageRect
    }
}
