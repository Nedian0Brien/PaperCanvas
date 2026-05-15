import Foundation
import SwiftData

@Model
final class PaperFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    @Relationship(deleteRule: .nullify, inverse: \PaperDocument.folder)
    var documents: [PaperDocument] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.updatedAt = .now
        self.deletedAt = nil
    }
}

extension PaperFolder {
    var isDeleted: Bool {
        deletedAt != nil
    }
}
