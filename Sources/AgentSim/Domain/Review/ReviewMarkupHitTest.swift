import Foundation

/// Drawing-tool hit testing against a pre-flattened element list.
///
/// `ReviewElement.frame` is in device points — the same unit the
/// agent-canvas → bulk-create flow stores, and the same unit the
/// browser canvas converts to before calling these helpers. Inputs
/// (`rect`, `path`) are likewise in device points; the JS overlay
/// in `sim-ax-inspector.js` and `review.js` projects from CSS pixel
/// space before calling.
///
/// Both helpers return element paths (`/`, `/children/0`, …) — the
/// stable identifier shared by `ReviewElement.axNodePath`,
/// `ReviewTaskElementInput.axNodePath`, and the AX tree on disk.
/// Callers convert paths back to elements (or `ReviewTaskElementInput`
/// rows for a queue submission) themselves.
///
/// Intersection is the standard CGRect half-open convention:
/// `[origin, origin + size)`. A zero-area rect / single-point degenerate
/// case falls back to "any element whose frame contains the point",
/// which keeps `select` ≡ `rectangle({size: 0})` and reduces the API
/// surface to two callers covering three tools.
enum ReviewMarkupHitTest {

    /// Elements whose frames intersect the supplied rectangle.
    /// Zero-area rects degrade to a single-point hit test against
    /// the rect's origin.
    static func rectangleHits(rect: Rect, elements: [ReviewElement]) -> [String] {
        if rect.size.width == 0 && rect.size.height == 0 {
            return brushHits(path: [rect.origin], elements: elements)
        }
        return elements
            .filter { intersects(rect, $0.frame) }
            .map(\.axNodePath)
    }

    /// Elements that contain at least one of the path points.
    /// Order matches the supplied element list (not the path order);
    /// callers that need stroke-order should iterate the path
    /// themselves.
    static func brushHits(path: [Point], elements: [ReviewElement]) -> [String] {
        guard !path.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for element in elements where path.contains(where: { contains(element.frame, $0) }) {
            if seen.insert(element.axNodePath).inserted {
                out.append(element.axNodePath)
            }
        }
        return out
    }

    private static func intersects(_ a: Rect, _ b: Rect) -> Bool {
        let aMinX = a.origin.x, aMaxX = aMinX + a.size.width
        let aMinY = a.origin.y, aMaxY = aMinY + a.size.height
        let bMinX = b.origin.x, bMaxX = bMinX + b.size.width
        let bMinY = b.origin.y, bMaxY = bMinY + b.size.height
        return aMinX < bMaxX && bMinX < aMaxX
            && aMinY < bMaxY && bMinY < aMaxY
    }

    private static func contains(_ frame: Rect, _ p: Point) -> Bool {
        let minX = frame.origin.x
        let minY = frame.origin.y
        let maxX = minX + frame.size.width
        let maxY = minY + frame.size.height
        return p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }
}
