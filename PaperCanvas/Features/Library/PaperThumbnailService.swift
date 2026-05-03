import Foundation
import UIKit
import PDFKit

@MainActor
final class PaperThumbnailService {
    static let shared = PaperThumbnailService()

    private let fm = FileManager.default
    private let maxDimension: CGFloat = 240

    private var directory: URL {
        let base = (try? fm.url(for: .cachesDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("paper-thumbnails", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(for paper: PaperDocument) -> URL {
        directory.appendingPathComponent("\(paper.id.uuidString).png")
    }

    func thumbnail(for paper: PaperDocument) -> UIImage? {
        let url = fileURL(for: paper)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func generateIfNeeded(for paper: PaperDocument) async {
        let url = fileURL(for: paper)
        if fm.fileExists(atPath: url.path) { return }
        guard let pdfURL = resolveURL(for: paper) else { return }
        let didStart = pdfURL.startAccessingSecurityScopedResource()
        defer { if didStart { pdfURL.stopAccessingSecurityScopedResource() } }
        guard let pdf = PDFDocument(url: pdfURL),
              let page = pdf.page(at: 0) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        try? image.pngData()?.write(to: url, options: .atomic)
    }

    func invalidate(for paper: PaperDocument) {
        try? fm.removeItem(at: fileURL(for: paper))
    }

    private func resolveURL(for paper: PaperDocument) -> URL? {
        if let bookmark = paper.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        if let s = paper.sourceURLString {
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
            if let u = URL(string: s), u.isFileURL { return u }
        }
        return nil
    }
}
