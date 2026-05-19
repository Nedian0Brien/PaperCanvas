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

    /// Bumped whenever the rendering algorithm changes meaningfully, so old
    /// cached PNGs (which may have been written with a broken palette) are
    /// not served by the new code.
    private static let cacheVersion = "v2"

    private func fileURL(for paper: PaperDocument, style: UIUserInterfaceStyle) -> URL {
        let suffix = style == .dark ? "-dark" : "-light"
        let name = "\(paper.id.uuidString)\(suffix)-\(Self.cacheVersion).png"
        return directory.appendingPathComponent(name)
    }

    func thumbnail(for paper: PaperDocument, style: UIUserInterfaceStyle) -> UIImage? {
        let url = fileURL(for: paper, style: style)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func generateIfNeeded(for paper: PaperDocument, style: UIUserInterfaceStyle) {
        _ = currentThumbnail(for: paper, style: style)
    }

    /// Returns the freshest thumbnail for this paper. Reads the on-disk cache
    /// when it is newer than the document's `updatedAt`; otherwise renders a
    /// fresh image, persists it to disk, and returns the in-memory copy. The
    /// cache is keyed by interface style so light- and dark-mode tiles do not
    /// overwrite one another, and palette colors are pre-resolved to static
    /// values before rasterization (relying on `UIColor.systemBackground`
    /// inside the renderer block proved unreliable — the dynamic provider
    /// would sometimes still resolve against the current screen trait
    /// collection instead of the explicit one we passed in, yielding white
    /// tiles in dark mode).
    func currentThumbnail(for paper: PaperDocument, style: UIUserInterfaceStyle) -> UIImage? {
        let styleLabel = style == .dark ? "dark" : (style == .light ? "light" : "unspec(\(style.rawValue))")
        let url = fileURL(for: paper, style: style)
        print("[ThumbnailDebug] currentThumbnail id=\(paper.id.uuidString.prefix(8)) kind=\(paper.documentKind) style=\(styleLabel) path=\(url.lastPathComponent)")
        if isCachedThumbnailFresh(at: url, comparedTo: paper.updatedAt),
           let data = try? Data(contentsOf: url),
           let cached = UIImage(data: data) {
            let probe = cached.pixelColor(at: CGPoint(x: 2, y: 2))
            print("[ThumbnailDebug]   cache HIT size=\(Int(cached.size.width))x\(Int(cached.size.height)) px(2,2)=\(probe)")
            return cached
        }
        print("[ThumbnailDebug]   cache MISS — rendering fresh")
        // Sweep up any legacy cache files (pre-style-suffix, and pre-cache-
        // version-bump) so we don't leak disk forever and so v1 PNGs with the
        // broken palette never get served.
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString).png"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString)-light.png"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString)-dark.png"))
        let palette = ThumbnailPalette(style: style)
        print("[ThumbnailDebug]   palette.pageBackground=\(palette.pageBackground.rgbaDebug) scrapFill=\(palette.scrapFill.rgbaDebug)")
        let rendered: UIImage
        switch paper.documentKind {
        case .note:
            rendered = renderPDFThumbnail(for: paper, palette: palette)
                ?? renderBlankPageTile(palette: palette)
        case .canvas:
            rendered = renderCanvasThumbnail(for: paper, palette: palette)
                ?? renderBlankPageTile(palette: palette)
        }
        let probe = rendered.pixelColor(at: CGPoint(x: 2, y: 2))
        print("[ThumbnailDebug]   rendered size=\(Int(rendered.size.width))x\(Int(rendered.size.height)) px(2,2)=\(probe)")
        if let png = rendered.pngData() {
            let writeOK = (try? png.write(to: url, options: .atomic)) != nil
            print("[ThumbnailDebug]   wrote png=\(png.count)B ok=\(writeOK) to=\(url.lastPathComponent)")
        } else {
            print("[ThumbnailDebug]   pngData() returned nil")
        }
        return rendered
    }

    /// Pre-resolved static colors that match the live canvas/note chrome in
    /// each interface style. These are intentionally plain RGB so they
    /// rasterize identically regardless of which trait collection is active
    /// when `UIGraphicsImageRenderer` runs its block.
    private struct ThumbnailPalette {
        let pageBackground: UIColor
        let scrapFill: UIColor
        let scrapStroke: UIColor
        let imagePlaceholder: UIColor

        init(style: UIUserInterfaceStyle) {
            switch style {
            case .dark:
                // Mirror UIColor.systemBackground / secondarySystemBackground
                // / systemGray4 in dark mode without relying on dynamic
                // resolution at draw time.
                pageBackground   = UIColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1)
                scrapFill        = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                scrapStroke      = UIColor(red: 0.35, green: 0.35, blue: 0.36, alpha: 1)
                imagePlaceholder = UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1)
            default:
                pageBackground   = UIColor.white
                scrapFill        = UIColor.white
                scrapStroke      = UIColor(red: 0.82, green: 0.82, blue: 0.84, alpha: 1)
                imagePlaceholder = UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
            }
        }
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
        try? fm.removeItem(at: fileURL(for: paper, style: .light))
        try? fm.removeItem(at: fileURL(for: paper, style: .dark))
    }

    private func renderBlankPageTile(palette: ThumbnailPalette) -> UIImage {
        let size = CGSize(width: maxDimension * 0.75, height: maxDimension)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            palette.pageBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func renderPDFThumbnail(for paper: PaperDocument, palette: ThumbnailPalette) -> UIImage? {
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
            palette.pageBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.scaleBy(x: scale, y: scale)
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    private func renderCanvasThumbnail(for paper: PaperDocument, palette: ThumbnailPalette) -> UIImage? {
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
            palette.pageBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: outputSize))

            let cg = ctx.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -sourceRect.origin.x, y: -sourceRect.origin.y)
            drawScraps(scraps, in: cg, palette: palette)
            cg.restoreGState()

            if hasStrokes {
                let drawingImage = drawing.image(from: sourceRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: outputSize))
            }
        }
    }

    private func drawScraps(_ scraps: [ScrapItem], in ctx: CGContext, palette: ThumbnailPalette) {
        let cornerRadius: CGFloat = 8
        let scrapFill = palette.scrapFill.cgColor
        let scrapStroke = palette.scrapStroke.cgColor
        let imagePlaceholder = palette.imagePlaceholder.cgColor
        for scrap in scraps {
            let frame = CGRect(x: scrap.positionX, y: scrap.positionY,
                               width: scrap.width, height: scrap.height)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: cornerRadius).cgPath
            switch scrap.kind {
            case .text:
                ctx.setFillColor(scrapFill)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(scrapStroke)
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
                    ctx.setFillColor(imagePlaceholder)
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                ctx.setStrokeColor(scrapStroke)
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

private extension UIColor {
    var rgbaDebug: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
        }
        return description
    }
}

private extension UIImage {
    /// Read a single pixel back from the rendered image. Used in debug logs to
    /// confirm what color was actually rasterized into the PNG.
    func pixelColor(at point: CGPoint) -> String {
        guard let cg = cgImage,
              let provider = cg.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return "n/a"
        }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return "oob" }
        let i = y * bpr + x * bpp
        let r = bytes[i]
        let g = bytes[i + 1]
        let b = bytes[i + 2]
        return String(format: "rgb(%d,%d,%d)", r, g, b)
    }
}
