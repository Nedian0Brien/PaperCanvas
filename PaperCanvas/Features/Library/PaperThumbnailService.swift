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
    private static let cacheVersion = "v4"

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
        let url = fileURL(for: paper, style: style)
        if isCachedThumbnailFresh(at: url, comparedTo: paper.updatedAt),
           let data = try? Data(contentsOf: url),
           let cached = UIImage(data: data) {
            return cached
        }
        // Sweep up legacy cache files from earlier cache schemes so we don't
        // leak disk forever and so older PNGs (written before the palette /
        // suffix changes) never get served by the freshness check.
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString).png"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString)-light.png"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString)-dark.png"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString)-light-v3.png"))
        try? fm.removeItem(at: directory.appendingPathComponent("\(paper.id.uuidString)-dark-v3.png"))
        let palette = ThumbnailPalette(style: style)
        let rendered: UIImage
        switch paper.documentKind {
        case .note:
            if paper.hasPDFSource {
                rendered = renderPDFThumbnail(for: paper, palette: palette)
                    ?? renderBlankNoteThumbnail(for: paper, palette: palette)
            } else {
                rendered = renderBlankNoteThumbnail(for: paper, palette: palette)
            }
        case .canvas:
            rendered = renderCanvasThumbnail(for: paper, palette: palette)
                ?? renderEmptyCanvasThumbnail(for: paper, palette: palette)
        }
        if let png = rendered.pngData() {
            try? png.write(to: url, options: .atomic)
        }
        return rendered
    }

    /// Pre-resolved static colors that match the live canvas/note chrome in
    /// each interface style. These are intentionally plain RGB so they
    /// rasterize identically regardless of which trait collection is active
    /// when `UIGraphicsImageRenderer` runs its block.
    private struct ThumbnailPalette {
        let style: UIUserInterfaceStyle
        let pageBackground: UIColor
        let scrapFill: UIColor
        let scrapStroke: UIColor
        let imagePlaceholder: UIColor
        let scrapText: UIColor
        let patternStroke: UIColor
        let patternDot: UIColor
        let ruleLine: UIColor
        let ruleStrong: UIColor

        init(style: UIUserInterfaceStyle) {
            self.style = style
            switch style {
            case .dark:
                // Slightly lifted off pure black so the page itself reads
                // against the surrounding dark card chrome and so the scrap
                // chips have somewhere to contrast against.
                pageBackground   = UIColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1)
                scrapFill        = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)
                scrapStroke      = UIColor(red: 0.42, green: 0.42, blue: 0.45, alpha: 1)
                imagePlaceholder = UIColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 1)
                scrapText        = UIColor(white: 0.92, alpha: 1)
                patternStroke    = UIColor(white: 1.0, alpha: 0.18)
                patternDot       = UIColor(white: 1.0, alpha: 0.32)
                ruleLine         = UIColor(white: 1.0, alpha: 0.28)
                ruleStrong       = UIColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 0.55)
            default:
                pageBackground   = UIColor.white
                scrapFill        = UIColor.white
                scrapStroke      = UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)
                imagePlaceholder = UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
                scrapText        = UIColor(white: 0.18, alpha: 1)
                patternStroke    = UIColor(white: 0.0, alpha: 0.16)
                patternDot       = UIColor(white: 0.0, alpha: 0.34)
                ruleLine         = UIColor(white: 0.0, alpha: 0.22)
                ruleStrong       = UIColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 0.55)
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

    /// Empty-state tile for a canvas with no strokes or scraps yet — draws
    /// the canvas's background pattern so the user can still tell which kind
    /// of paper they picked.
    private func renderEmptyCanvasThumbnail(for paper: PaperDocument,
                                            palette: ThumbnailPalette) -> UIImage {
        let size = CGSize(width: maxDimension * 0.75, height: maxDimension)
        let renderer = UIGraphicsImageRenderer(size: size)
        let background = CanvasBackground(rawValue: paper.canvasBackgroundRaw) ?? .dots
        return renderer.image { ctx in
            palette.pageBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            drawCanvasPattern(background, in: CGRect(origin: .zero, size: size),
                              context: ctx.cgContext, palette: palette,
                              spacing: 18, lineWidth: 0.6, dotRadius: 0.9)
        }
    }

    private func renderBlankNoteThumbnail(for paper: PaperDocument,
                                          palette: ThumbnailPalette) -> UIImage {
        let style = paper.notePageStyle
        let pageSize = CGSize(width: paper.notePageWidth, height: paper.notePageHeight)
        let scale = maxDimension / max(pageSize.width, pageSize.height)
        let outSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        let renderer = UIGraphicsImageRenderer(size: outSize)
        let drawing: PKDrawing = {
            if let data = paper.drawingData,
               let d = try? PKDrawing(data: data) { return d }
            return PKDrawing()
        }()
        return renderer.image { ctx in
            palette.pageBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: outSize))
            // Draw the rulings directly at output scale (rather than scaling
            // a page-sized context down) so hairlines don't collapse to
            // sub-pixel widths and vanish in the thumbnail.
            drawNoteRulings(style: style,
                            in: CGRect(origin: .zero, size: outSize),
                            context: ctx.cgContext,
                            palette: palette)
            if !drawing.strokes.isEmpty {
                let firstPage = CGRect(origin: .zero, size: pageSize)
                let inkImage = drawing.image(from: firstPage, scale: scale)
                inkImage.draw(in: CGRect(origin: .zero, size: outSize))
            }
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
            // PDFs render their own white page; fill white regardless of
            // style so dark-mode thumbs don't show black bars in margin
            // areas the PDF leaves transparent.
            UIColor.white.setFill()
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
        let background = CanvasBackground(rawValue: paper.canvasBackgroundRaw) ?? .dots

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { ctx in
            palette.pageBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: outputSize))

            // Background pattern is drawn at output scale so dots/lines stay
            // crisp regardless of how zoomed-out the captured region is.
            drawCanvasPattern(background,
                              in: CGRect(origin: .zero, size: outputSize),
                              context: ctx.cgContext,
                              palette: palette,
                              spacing: 16,
                              lineWidth: 0.6,
                              dotRadius: 0.9)

            let cg = ctx.cgContext
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -sourceRect.origin.x, y: -sourceRect.origin.y)
            drawScraps(scraps, in: cg, palette: palette, scale: scale)
            cg.restoreGState()

            if hasStrokes {
                let drawingImage = drawing.image(from: sourceRect, scale: scale)
                drawingImage.draw(in: CGRect(origin: .zero, size: outputSize))
            }
        }
    }

    private func drawScraps(_ scraps: [ScrapItem],
                            in ctx: CGContext,
                            palette: ThumbnailPalette,
                            scale: CGFloat) {
        let cornerRadius: CGFloat = 8
        let scrapFill = palette.scrapFill.cgColor
        let scrapStroke = palette.scrapStroke.cgColor
        let imagePlaceholder = palette.imagePlaceholder.cgColor
        // Stroke width is specified in canvas-space units; scale it up so
        // the drawn outline lands close to 1 device pixel at the thumbnail's
        // final resolution.
        let strokeWidth = max(1.0 / scale, 0.5)
        for scrap in scraps {
            let frame = CGRect(x: scrap.positionX, y: scrap.positionY,
                               width: scrap.width, height: scrap.height)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: cornerRadius).cgPath
            switch scrap.kind {
            case .text:
                ctx.setFillColor(scrapFill)
                ctx.addPath(path)
                ctx.fillPath()
                if let text = scrap.text, !text.isEmpty {
                    drawScrapText(text, in: frame, context: ctx,
                                  color: palette.scrapText, scale: scale)
                }
                ctx.setStrokeColor(scrapStroke)
                ctx.setLineWidth(strokeWidth)
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
                ctx.setLineWidth(strokeWidth)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
    }

    /// Renders the first few lines of a text scrap so it doesn't appear as
    /// an empty placeholder in the canvas thumbnail. Font size is chosen in
    /// canvas-space units so it stays readable after the scrap is shrunk
    /// down to the thumbnail's render scale.
    private func drawScrapText(_ text: String,
                               in frame: CGRect,
                               context: CGContext,
                               color: UIColor,
                               scale: CGFloat) {
        let padding: CGFloat = 12
        let textRect = frame.insetBy(dx: padding, dy: padding)
        guard textRect.width > 4, textRect.height > 4 else { return }
        // Pick a font that renders to roughly 9pt at the final thumbnail
        // resolution. Clamp so very large scraps don't pick a huge font.
        let targetThumbPt: CGFloat = 9
        let fontSize = min(max(targetThumbPt / max(scale, 0.001), 10), frame.height * 0.35)
        let font = UIFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let snippet = String(text.prefix(220))
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        (snippet as NSString).draw(with: textRect,
                                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                   attributes: attrs,
                                   context: nil)
    }

    private func drawCanvasPattern(_ background: CanvasBackground,
                                   in rect: CGRect,
                                   context: CGContext,
                                   palette: ThumbnailPalette,
                                   spacing: CGFloat,
                                   lineWidth: CGFloat,
                                   dotRadius: CGFloat) {
        guard background != .plain else { return }
        context.saveGState()
        defer { context.restoreGState() }
        switch background {
        case .plain:
            return
        case .dots:
            context.setFillColor(palette.patternDot.cgColor)
            var y = spacing
            while y < rect.maxY {
                var x = spacing
                while x < rect.maxX {
                    context.fillEllipse(in: CGRect(x: x - dotRadius, y: y - dotRadius,
                                                   width: dotRadius * 2,
                                                   height: dotRadius * 2))
                    x += spacing
                }
                y += spacing
            }
        case .grid:
            context.setStrokeColor(palette.patternStroke.cgColor)
            context.setLineWidth(lineWidth)
            var x = spacing
            while x < rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += spacing
            }
            var y = spacing
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            context.strokePath()
        case .lines:
            context.setStrokeColor(palette.patternStroke.cgColor)
            context.setLineWidth(lineWidth)
            var y = spacing
            while y < rect.maxY {
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += spacing
            }
            context.strokePath()
        }
    }

    /// Note rulings drawn directly at thumbnail resolution. Matches the live
    /// page styling (margins, cornell regions) but with stroke widths and
    /// colors picked to survive scaling — `NotePageStyle.drawBackground`
    /// uses 0.5pt hairlines and `UIColor.label` opacity that collapse to
    /// nothing at thumbnail scale.
    private func drawNoteRulings(style: NotePageStyle,
                                 in rect: CGRect,
                                 context: CGContext,
                                 palette: ThumbnailPalette) {
        guard style != .plain else { return }
        let pageSize = NotePageStyle.defaultPageSize
        let scaleX = rect.width / pageSize.width
        let scaleY = rect.height / pageSize.height
        let insets = style.pageInsets
        let ruleRect = CGRect(
            x: rect.minX + insets.left * scaleX,
            y: rect.minY + insets.top * scaleY,
            width: rect.width - (insets.left + insets.right) * scaleX,
            height: rect.height - (insets.top + insets.bottom) * scaleY
        )
        let spacingY = style.ruleSpacing * scaleY
        let spacingX = style.ruleSpacing * scaleX
        let lineWidth: CGFloat = 0.75
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(lineWidth)
        switch style {
        case .plain:
            return
        case .lined:
            context.setStrokeColor(palette.ruleLine.cgColor)
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                context.move(to: CGPoint(x: ruleRect.minX, y: y))
                context.addLine(to: CGPoint(x: ruleRect.maxX, y: y))
                y += spacingY
            }
            context.strokePath()
            context.setStrokeColor(palette.ruleStrong.cgColor)
            let marginX = ruleRect.minX - 32 * scaleX
            context.move(to: CGPoint(x: marginX, y: rect.minY + 24 * scaleY))
            context.addLine(to: CGPoint(x: marginX, y: rect.maxY - 24 * scaleY))
            context.strokePath()
        case .grid:
            context.setStrokeColor(palette.ruleLine.cgColor)
            var x = ruleRect.minX
            while x <= ruleRect.maxX {
                context.move(to: CGPoint(x: x, y: ruleRect.minY))
                context.addLine(to: CGPoint(x: x, y: ruleRect.maxY))
                x += spacingX
            }
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                context.move(to: CGPoint(x: ruleRect.minX, y: y))
                context.addLine(to: CGPoint(x: ruleRect.maxX, y: y))
                y += spacingY
            }
            context.strokePath()
        case .dots:
            context.setFillColor(palette.patternDot.cgColor)
            let r: CGFloat = 1.1
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                var x = ruleRect.minX
                while x <= ruleRect.maxX {
                    context.fillEllipse(in: CGRect(x: x - r, y: y - r,
                                                   width: r * 2, height: r * 2))
                    x += spacingX
                }
                y += spacingY
            }
        case .cornell:
            let cueX = rect.minX + insets.left * scaleX
            let summaryY = rect.maxY - insets.bottom * scaleY
            let horizontalStartX = rect.minX + 24 * scaleX
            let horizontalEndX = rect.maxX - insets.right * scaleX
            context.setStrokeColor(palette.ruleLine.cgColor)
            var y = ruleRect.minY
            while y <= ruleRect.maxY {
                context.move(to: CGPoint(x: horizontalStartX, y: y))
                context.addLine(to: CGPoint(x: horizontalEndX, y: y))
                y += spacingY
            }
            context.strokePath()
            context.setStrokeColor(UIColor(white: palette.style == .dark ? 1 : 0,
                                           alpha: 0.45).cgColor)
            context.setLineWidth(1.0)
            context.move(to: CGPoint(x: cueX, y: rect.minY + 32 * scaleY))
            context.addLine(to: CGPoint(x: cueX, y: summaryY))
            context.move(to: CGPoint(x: rect.minX + 24 * scaleX, y: summaryY))
            context.addLine(to: CGPoint(x: rect.maxX - 24 * scaleX, y: summaryY))
            context.strokePath()
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
