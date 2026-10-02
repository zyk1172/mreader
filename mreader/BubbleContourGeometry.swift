import CoreGraphics
import Foundation

/// A conservative inscribed rectangle, not the contour's bounding box. Every
/// accepted grid cell lies inside the path with a border-distance margin. This
/// also handles concave contours; testing only the four outer corners would not.
nonisolated enum BubbleContourGeometry {
    static func safeRectangle(polygon: [CGPoint], bounds: CGRect) -> CGRect? {
        guard polygon.count >= 3, polygon.count <= 512, bounds.width > 0, bounds.height > 0,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let points = polygon.map { CGPoint(x: ($0.x - bounds.minX) / bounds.width,
                                           y: ($0.y - bounds.minY) / bounds.height) }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let n = 40
        let radius = sqrt(CGFloat(2)) / CGFloat(n * 2) + 0.025
        var heights = [Int](repeating: 0, count: n)
        var best = CGRect.null
        var bestArea = 0
        for y in 0..<n {
            for x in 0..<n {
                let center = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(n), y: (CGFloat(y) + 0.5) / CGFloat(n))
                let inside = path.contains(center, using: .evenOdd)
                    && points.indices.allSatisfy { i in
                        distance(center, to: points[i], points[(i + 1) % points.count]) >= radius
                    }
                heights[x] = inside ? heights[x] + 1 : 0
            }
            // Largest all-safe rectangle ending in this row. At 40 columns this
            // bounded search is cheaper and less error-prone than rasterizing page pixels.
            for left in 0..<n {
                var height = heights[left]
                for right in left..<n {
                    height = min(height, heights[right])
                    let area = height * (right - left + 1)
                    if area > bestArea {
                        bestArea = area
                        best = CGRect(x: CGFloat(left) / CGFloat(n), y: CGFloat(y + 1 - height) / CGFloat(n),
                                      width: CGFloat(right - left + 1) / CGFloat(n), height: CGFloat(height) / CGFloat(n))
                    }
                }
            }
        }
        guard bestArea >= 4 else { return nil }
        return CGRect(x: bounds.minX + best.minX * bounds.width, y: bounds.minY + best.minY * bounds.height,
                      width: best.width * bounds.width, height: best.height * bounds.height)
    }

    private static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
}
