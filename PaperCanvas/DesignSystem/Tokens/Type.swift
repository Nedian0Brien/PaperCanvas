import SwiftUI

enum AppType {
    static let title: Font = .system(.title2, design: .default).weight(.semibold)
    static let headline: Font = .system(.headline)
    static let body: Font = .system(.body)
    static let bodyEmphasized: Font = .system(.body).weight(.semibold)
    static let callout: Font = .system(.callout)
    static let caption: Font = .system(.caption)
    static let monoCaption: Font = .system(.caption, design: .monospaced)

    static let display: Font = .system(size: 28, weight: .semibold, design: .rounded)
    static let toolGlyph: Font = .system(size: 18, weight: .medium)
}
