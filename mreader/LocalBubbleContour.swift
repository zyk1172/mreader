import CoreGraphics
import Foundation

/// Pixel evidence for closed, light speech balloons. Rejections retain the
/// original detector box; no ellipse or invented contour is substituted.
nonisolated enum LocalBubbleContour {
    static let revision = "closed-light-balloon-v1"

    static func recover(in image: CGImage, balloon: CGRect, textRegions: [CGRect]) -> [CGPoint]? {
        let size = CGSize(width: image.width, height: image.height)
        let pixelRect = CGRect(x: balloon.minX * size.width, y: balloon.minY * size.height,
                               width: balloon.width * size.width, height: balloon.height * size.height).integral
            .intersection(CGRect(origin: .zero, size: size))
        guard pixelRect.width >= 12, pixelRect.height >= 12,
              let crop = image.cropping(to: pixelRect) else { return nil }
        let scale = min(1, 256 / max(pixelRect.width, pixelRect.height))
        let w = max(1, Int(pixelRect.width * scale)), h = max(1, Int(pixelRect.height * scale))
        var luma = [UInt8](repeating: 0, count: w * h)
        let rendered = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered, w >= 12, h >= 12 else { return nil }
        let localTexts = textRegions.filter { $0.intersects(balloon) }.map {
            CGRect(x: ($0.minX * size.width - pixelRect.minX) * CGFloat(w) / pixelRect.width,
                   y: ($0.minY * size.height - pixelRect.minY) * CGFloat(h) / pixelRect.height,
                   width: $0.width * size.width * CGFloat(w) / pixelRect.width,
                   height: $0.height * size.height * CGFloat(h) / pixelRect.height)
        }
        guard !localTexts.isEmpty else { return nil }
        // Find a light seed close to the OCR union, avoiding the dark characters.
        let text = localTexts.reduce(CGRect.null) { $0.union($1) }
        let cx = min(w - 2, max(1, Int(text.midX))), cy = min(h - 2, max(1, Int(text.midY)))
        var seed: Int?
        for r in 0...max(4, min(w, h) / 3) {
            if seed != nil { break }
            for y in max(1, cy-r)...min(h-2, cy+r) {
                for x in max(1, cx-r)...min(w-2, cx+r) where abs(x-cx) == r || abs(y-cy) == r {
                    if luma[y*w+x] >= 225 { seed = y*w+x; break }
                }
                if seed != nil { break }
            }
        }
        guard let seed else { return nil }
        var visited = [Bool](repeating: false, count: w*h)
        var queue = [seed], cursor = 0
        visited[seed] = true
        var boundary: [CGPoint] = []
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1
            let x = index % w, y = index / w
            // A region reaching the crop boundary has no observed closed border.
            guard x > 0, y > 0, x < w-1, y < h-1 else { return nil }
            var isBoundary = false
            for next in [index-1, index+1, index-w, index+w] {
                if luma[next] < 210 { isBoundary = true; continue }
                if !visited[next] { visited[next] = true; queue.append(next) }
            }
            if isBoundary { boundary.append(CGPoint(x: CGFloat(x)+0.5, y: CGFloat(y)+0.5)) }
        }
        guard queue.count >= w*h/10, queue.count <= w*h*9/10 else { return nil }
        // Exclude text holes from the external boundary. Convexity is required:
        // irregular/concave cases must not be filled across unobserved artwork.
        let hull = convexHull(boundary)
        guard hull.count >= 8 else { return nil }
        let hullArea = abs(hull.indices.reduce(CGFloat.zero) { sum, i in
            let a = hull[i], b = hull[(i+1)%hull.count]
            return sum + a.x*b.y-b.x*a.y
        }) / 2
        guard hullArea > 0, CGFloat(queue.count) / hullArea >= 0.88 else { return nil }
        let path = CGMutablePath(); path.addLines(between: hull); path.closeSubpath()
        // The hull must not bridge a dark border or separate balloon. Sample its
        // interior away from the OCR ink; reject instead of hiding picture pixels.
        for y in stride(from: 1, to: h-1, by: 2) {
            for x in stride(from: 1, to: w-1, by: 2) {
                let point = CGPoint(x: CGFloat(x)+0.5, y: CGFloat(y)+0.5)
                if path.contains(point), !visited[y*w+x],
                   !localTexts.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) { return nil }
            }
        }
        guard localTexts.allSatisfy({ rect in
            path.contains(CGPoint(x: rect.midX, y: rect.midY))
        }) else { return nil }
        return hull.map { CGPoint(x: (pixelRect.minX + $0.x * pixelRect.width / CGFloat(w)) / size.width,
                                 y: (pixelRect.minY + $0.y * pixelRect.height / CGFloat(h)) / size.height) }
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return [] }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count-2], lower[lower.count-1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count-2], upper[upper.count-1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}
