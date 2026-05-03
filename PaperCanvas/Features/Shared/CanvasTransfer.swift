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
}
