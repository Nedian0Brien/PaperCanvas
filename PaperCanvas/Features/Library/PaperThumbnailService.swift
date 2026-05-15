import Foundation
import UIKit
import PDFKit
import PencilKit

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
        let image: UIImage?
        switch paper.documentKind {
        case .note:
            image = renderPDFThumbnail(for: paper)
        case .canvas:
            image = renderCanvasThumbnail(for: paper)
        }
        guard let png = image?.pngData() else { return }
        try? png.write(to: url, options: .atomic)
    }

    func invalidate(for paper: PaperDocument) {
        try? fm.removeItem(at: fileURL(for: paper))
    }

    private func renderPDFThumbnail(for paper: PaperDocument) -> UIImage? {
        guard let pdfURL = resolveURL(for: paper) else { return nil }
        let didStart = pdfURL.startAccessingSecurityScopedResource()
        defer { if didStart { pdfURL.stopAccessingSecurityScopedResource() } }
        guard let pdf = PDFDocument(url: pdfURL),
              let page = pdf.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    private func renderCanvasThumbnail(for paper: PaperDocument) -> UIImage? {
        let drawing: PKDrawing = {
            if let data = paper.drawingData,
               let d = try? PKDrawing(data: data) { return d }
            return PKDrawing()
        }()

        let strokesBounds = drawing.bounds
        let hasStrokes = !drawing.strokes.isEmpty && !strokesBounds.isNull && !strokesBounds.isInfinite

        let sourceRect: CGRect
        if hasStrokes {
            sourceRect = strokesBounds.insetBy(dx: -48, dy: -48)
        } else {
            // Empty canvas: show a small placeholder area centered around origin
            sourceRect = CGRect(x: -400, y: -300, width: 800, height: 600)
        }
        let scale = maxDimension / max(sourceRect.width, sourceRect.height)
        let outputSize = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: outputSize))
            if hasStrokes {
                let drawingImage = drawing.image(from: sourceRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: outputSize))
            }
        }
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
