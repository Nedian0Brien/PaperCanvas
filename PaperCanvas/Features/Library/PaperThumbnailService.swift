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

    func generateIfNeeded(for paper: PaperDocument) {
        _ = currentThumbnail(for: paper)
    }

    /// Returns the freshest thumbnail for this paper. Reads the on-disk cache
    /// when it is newer than the document's `updatedAt`; otherwise renders a
    /// fresh image, persists it to disk, and returns the in-memory copy. Using
    /// this single entry point removes the write-then-read race that previously
    /// caused the library to fall back to the SF Symbol placeholder when the
    /// freshly written PNG could not yet be read back.
    func currentThumbnail(for paper: PaperDocument) -> UIImage? {
        let url = fileURL(for: paper)
        if isCachedThumbnailFresh(at: url, comparedTo: paper.updatedAt),
           let data = try? Data(contentsOf: url),
           let cached = UIImage(data: data) {
            return cached
        }
        let rendered: UIImage
        switch paper.documentKind {
        case .note:
            rendered = renderPDFThumbnail(for: paper) ?? renderBlankPageTile()
        case .canvas:
            rendered = renderCanvasThumbnail(for: paper) ?? renderBlankPageTile()
        }
        if let png = rendered.pngData() {
            try? png.write(to: url, options: .atomic)
        }
        return rendered
    }

    private func isCachedThumbnailFresh(at url: URL, comparedTo paperUpdatedAt: Date) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return modDate >= paperUpdatedAt
    }

    func invalidate(for paper: PaperDocument) {
        try? fm.removeItem(at: fileURL(for: paper))
    }

    private func renderBlankPageTile() -> UIImage {
        let size = CGSize(width: maxDimension * 0.75, height: maxDimension)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
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

        let scraps = paper.scrapItems
        let scrapFrames: [CGRect] = scraps.map {
            CGRect(x: $0.positionX, y: $0.positionY, width: $0.width, height: $0.height)
        }
        let hasScraps = !scrapFrames.isEmpty

        var contentBounds: CGRect = .null
        if hasStrokes { contentBounds = contentBounds.union(strokesBounds) }
        for f in scrapFrames { contentBounds = contentBounds.union(f) }

        guard hasStrokes || hasScraps,
              !contentBounds.isNull, !contentBounds.isInfinite else {
            return nil
        }
        let sourceRect = contentBounds.insetBy(dx: -48, dy: -48)
        let scale = maxDimension / max(sourceRect.width, sourceRect.height)
        let outputSize = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: outputSize))

            let cg = ctx.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -sourceRect.origin.x, y: -sourceRect.origin.y)
            drawScraps(scraps, in: cg)
            cg.restoreGState()

            if hasStrokes {
                let drawingImage = drawing.image(from: sourceRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: outputSize))
            }
        }
    }

    private func drawScraps(_ scraps: [ScrapItem], in ctx: CGContext) {
        let cornerRadius: CGFloat = 8
        for scrap in scraps {
            let frame = CGRect(x: scrap.positionX, y: scrap.positionY,
                               width: scrap.width, height: scrap.height)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: cornerRadius).cgPath
            switch scrap.kind {
            case .text:
                ctx.setFillColor(UIColor.systemBackground.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(UIColor.systemGray4.cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(path)
                ctx.strokePath()
            case .image:
                if let data = scrap.imageData, let image = UIImage(data: data) {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    image.draw(in: frame)
                    ctx.restoreGState()
                } else {
                    ctx.setFillColor(UIColor.systemGray5.cgColor)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                ctx.setStrokeColor(UIColor.systemGray4.cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(path)
                ctx.strokePath()
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
