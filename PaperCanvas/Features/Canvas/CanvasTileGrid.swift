import CoreGraphics
import PencilKit

/// Divides the infinite canvas into a uniform grid of tiles and exposes utilities
/// to determine which tiles currently host content and which neighbors should be
/// made available for the user to expand into.
///
/// Tiles are addressed by integer `(i, j)` coordinates where tile `(i, j)` covers
/// the rectangle `(i * tileSize, j * tileSize, tileSize, tileSize)` in canvas
/// (un-zoomed) coordinates.
enum CanvasTileGrid {
    /// Side length of each square tile in canvas points. Matches the legacy
    /// scroll-driven expansion step so existing documents feel familiar.
    static let tileSize: CGFloat = 1500

    /// Tiles intersected by any stroke or scrap.
    static func occupiedTiles(drawing: PKDrawing, scraps: [ScrapItem]) -> Set<TileCoord> {
        var result: Set<TileCoord> = []
        for stroke in drawing.strokes {
            insertTiles(intersecting: stroke.renderBounds, into: &result)
        }
        for scrap in scraps {
            let rect = CGRect(
                x: CGFloat(scrap.positionX),
                y: CGFloat(scrap.positionY),
                width: max(1, CGFloat(scrap.width)),
                height: max(1, CGFloat(scrap.height))
            )
            insertTiles(intersecting: rect, into: &result)
        }
        return result
    }

    /// `occupied` plus the four axis-aligned neighbors of every occupied tile.
    /// The user can draw into an empty neighbor; doing so will mark that tile
    /// occupied on the next recompute, which in turn unlocks its neighbors.
    static func activeTiles(occupied: Set<TileCoord>) -> Set<TileCoord> {
        var result = occupied
        for tile in occupied {
            result.insert(TileCoord(tile.i - 1, tile.j))
            result.insert(TileCoord(tile.i + 1, tile.j))
            result.insert(TileCoord(tile.i, tile.j - 1))
            result.insert(TileCoord(tile.i, tile.j + 1))
        }
        return result
    }

    /// Bounding rectangle in canvas coordinates of the supplied tile set, or
    /// `nil` when the set is empty.
    static func boundingRect(of tiles: Set<TileCoord>) -> CGRect? {
        guard let first = tiles.first else { return nil }
        var minI = first.i, maxI = first.i
        var minJ = first.j, maxJ = first.j
        for tile in tiles {
            if tile.i < minI { minI = tile.i }
            if tile.i > maxI { maxI = tile.i }
            if tile.j < minJ { minJ = tile.j }
            if tile.j > maxJ { maxJ = tile.j }
        }
        return CGRect(
            x: CGFloat(minI) * tileSize,
            y: CGFloat(minJ) * tileSize,
            width: CGFloat(maxI - minI + 1) * tileSize,
            height: CGFloat(maxJ - minJ + 1) * tileSize
        )
    }

    /// Tile under a point in canvas coordinates.
    static func tile(at point: CGPoint) -> TileCoord {
        TileCoord(
            Int(floor(point.x / tileSize)),
            Int(floor(point.y / tileSize))
        )
    }

    private static func insertTiles(intersecting rect: CGRect, into set: inout Set<TileCoord>) {
        guard rect.width >= 0, rect.height >= 0 else { return }
        let minI = Int(floor(rect.minX / tileSize))
        let maxI = Int(floor(rect.maxX / tileSize))
        let minJ = Int(floor(rect.minY / tileSize))
        let maxJ = Int(floor(rect.maxY / tileSize))
        guard minI <= maxI, minJ <= maxJ else { return }
        for i in minI...maxI {
            for j in minJ...maxJ {
                set.insert(TileCoord(i, j))
            }
        }
    }
}

struct TileCoord: Hashable {
    let i: Int
    let j: Int

    init(_ i: Int, _ j: Int) {
        self.i = i
        self.j = j
    }
}
