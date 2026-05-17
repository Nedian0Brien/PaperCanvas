import Foundation
import SwiftData

enum PaperDocumentKind: String, Codable, CaseIterable, Identifiable {
    case note
    case canvas

    var id: Self { self }

    var label: String {
        switch self {
        case .note: return "노트"
        case .canvas: return "캔버스"
        }
    }

    var systemImage: String {
        switch self {
        case .note: return "doc.text"
        case .canvas: return "note.text"
        }
    }
}

@Model
final class PaperDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var documentKindRawValue: String = ""
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
    var isPinned: Bool = false
    var pinnedAt: Date?
    var deletedAt: Date?
    var companionPaperID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \ScrapItem.document)
    var scrapItems: [ScrapItem] = []

    @Relationship(deleteRule: .cascade, inverse: \PageInk.document)
    var pageInks: [PageInk] = []

    @Relationship(deleteRule: .cascade, inverse: \PDFTextHighlight.document)
    var textHighlights: [PDFTextHighlight] = []

    @Relationship(deleteRule: .cascade, inverse: \PDFRegionMark.document)
    var regionMarks: [PDFRegionMark] = []

    var folder: PaperFolder?

    init(title: String,
         kind: PaperDocumentKind = .note,
         bookmarkData: Data? = nil,
         sourceURLString: String? = nil) {
        self.id = UUID()
        self.title = title
        self.documentKindRawValue = kind.rawValue
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
        self.isPinned = false
        self.pinnedAt = nil
        self.deletedAt = nil
        self.companionPaperID = nil
    }
}

extension PaperDocument {
    var documentKind: PaperDocumentKind {
        get {
            PaperDocumentKind(rawValue: documentKindRawValue) ?? inferredLegacyDocumentKind
        }
        set {
            documentKindRawValue = newValue.rawValue
        }
    }

    var hasExplicitDocumentKind: Bool {
        PaperDocumentKind(rawValue: documentKindRawValue) != nil
    }

    var inferredLegacyDocumentKind: PaperDocumentKind {
        bookmarkData == nil && sourceURLString == nil ? .canvas : .note
    }

    var isDeleted: Bool {
        deletedAt != nil
    }
}
