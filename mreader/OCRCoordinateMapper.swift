import CoreGraphics

enum OCRImageFitMode: Sendable {
    case fitScreen
    case fitWidth
    case fitHeight
    case original
}

struct OCRDisplayTransform: Sendable, Equatable {
    let imageRect: CGRect
}

nonisolated struct OCRDisplayPolygon: Sendable, Equatable {
    let rect: CGRect
    let localPoints: [CGPoint]
}

enum OCRCoordinateMapper {
    nonisolated static func displayTransform(
        sourcePixelSize: CGSize,
        containerSize: CGSize,
        fitMode: OCRImageFitMode,
        zoomScale: CGFloat = 1,
        panOffset: CGSize = .zero
    ) -> OCRDisplayTransform {
        guard sourcePixelSize.width > 0,
              sourcePixelSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return OCRDisplayTransform(imageRect: .zero)
        }

        let widthScale = containerSize.width / sourcePixelSize.width
        let heightScale = containerSize.height / sourcePixelSize.height
        let fitScale: CGFloat
        switch fitMode {
        case .fitWidth:
            fitScale = widthScale
        case .fitHeight:
            fitScale = heightScale
        case .fitScreen:
            fitScale = min(widthScale, heightScale)
        case .original:
            // 原始尺寸：不放大；小图 1:1，大图等比缩小适配容器
            fitScale = min(1, min(widthScale, heightScale))
        }

        let baseSize = CGSize(
            width: sourcePixelSize.width * fitScale,
            height: sourcePixelSize.height * fitScale
        )
        let appliedZoom = max(zoomScale, 0.01)
        let displayedSize = CGSize(
            width: baseSize.width * appliedZoom,
            height: baseSize.height * appliedZoom
        )
        let center = CGPoint(
            x: containerSize.width / 2 + panOffset.width,
            y: containerSize.height / 2 + panOffset.height
        )
        return OCRDisplayTransform(imageRect: CGRect(
            x: center.x - displayedSize.width / 2,
            y: center.y - displayedSize.height / 2,
            width: displayedSize.width,
            height: displayedSize.height
        ))
    }

    nonisolated static func displayRect(
        forNormalizedPageRect rect: CGRect,
        using transform: OCRDisplayTransform
    ) -> CGRect {
        let imageRect = transform.imageRect
        return CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    nonisolated static func displayPoint(
        forNormalizedPagePoint point: CGPoint,
        using transform: OCRDisplayTransform
    ) -> CGPoint {
        let imageRect = transform.imageRect
        return CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }

    /// Maps a page-normalized contour into a shape-local rectangle without changing
    /// its page-space position. The small outset keeps a centered stroke from being
    /// clipped at the contour bounds.
    nonisolated static func displayPolygon(
        forNormalizedPagePoints points: [CGPoint],
        using transform: OCRDisplayTransform,
        strokeOutset: CGFloat = 1
    ) -> OCRDisplayPolygon? {
        let mapped = points.map {
            displayPoint(forNormalizedPagePoint: $0, using: transform)
        }.filter { $0.x.isFinite && $0.y.isFinite }
        guard mapped.count >= 3,
              let first = mapped.first else { return nil }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in mapped.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        guard maxX > minX, maxY > minY else { return nil }

        let outset = max(strokeOutset.isFinite ? strokeOutset : 0, 0)
        let rect = CGRect(
            x: minX - outset,
            y: minY - outset,
            width: maxX - minX + outset * 2,
            height: maxY - minY + outset * 2
        )
        let localPoints = mapped.map {
            CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY)
        }
        return OCRDisplayPolygon(rect: rect, localPoints: localPoints)
    }

    /// Finds a conservative rectangular text area fully inside a detected bubble
    /// contour. The returned rectangle is useful for glyph layout: fitting text in
    /// the contour's bounding box alone can place it outside oval or irregular sides.
    nonisolated static func interiorRect(
        for polygon: OCRDisplayPolygon,
        safetyInset: CGFloat = 0.92
    ) -> CGRect? {
        let points = polygon.localPoints
        guard points.count >= 3,
              polygon.rect.width > 0,
              polygon.rect.height > 0 else { return nil }

        let localBounds = CGRect(origin: .zero, size: polygon.rect.size)
        let centerSamples = 10
        let edgeSamples: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        var bestRect: CGRect?
        var bestArea: CGFloat = 0

        for row in 0...centerSamples {
            let y = localBounds.minY + localBounds.height * CGFloat(row) / CGFloat(centerSamples)
            for column in 0...centerSamples {
                let x = localBounds.minX + localBounds.width * CGFloat(column) / CGFloat(centerSamples)
                let center = CGPoint(x: x, y: y)
                guard contains(center, in: points) else { continue }

                var lower: CGFloat = 0
                var upper: CGFloat = 1
                for _ in 0..<14 {
                    let scale = (lower + upper) / 2
                    let candidate = CGRect(
                        x: center.x - localBounds.width * scale / 2,
                        y: center.y - localBounds.height * scale / 2,
                        width: localBounds.width * scale,
                        height: localBounds.height * scale
                    )
                    if isContained(candidate, in: points, samples: edgeSamples) {
                        lower = scale
                    } else {
                        upper = scale
                    }
                }

                let candidate = CGRect(
                    x: center.x - localBounds.width * lower / 2,
                    y: center.y - localBounds.height * lower / 2,
                    width: localBounds.width * lower,
                    height: localBounds.height * lower
                )
                let area = candidate.width * candidate.height
                if area > bestArea {
                    bestArea = area
                    bestRect = candidate
                }
            }
        }

        guard let bestRect, bestRect.width > 0, bestRect.height > 0 else { return nil }
        let inset = min(max(safetyInset.isFinite ? safetyInset : 0.92, 0.5), 1)
        let safeRect = CGRect(
            x: bestRect.midX - bestRect.width * inset / 2,
            y: bestRect.midY - bestRect.height * inset / 2,
            width: bestRect.width * inset,
            height: bestRect.height * inset
        )
        return safeRect.offsetBy(dx: polygon.rect.minX, dy: polygon.rect.minY)
    }

    nonisolated private static func isContained(
        _ rect: CGRect,
        in polygon: [CGPoint],
        samples: [CGFloat]
    ) -> Bool {
        for xFraction in samples {
            for yFraction in samples {
                let point = CGPoint(
                    x: rect.minX + rect.width * xFraction,
                    y: rect.minY + rect.height * yFraction
                )
                if !contains(point, in: polygon) { return false }
            }
        }
        return true
    }

    nonisolated private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.last!
        for current in polygon {
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let cross = (point.x - previous.x) * dy - (point.y - previous.y) * dx
            let dot = (point.x - previous.x) * dx + (point.y - previous.y) * dy
            let lengthSquared = dx * dx + dy * dy
            if abs(cross) <= 0.000_1,
               dot >= -0.000_1,
               dot <= lengthSquared + 0.000_1 {
                return true
            }

            if (current.y > point.y) != (previous.y > point.y) {
                let denominator = previous.y - current.y
                if abs(denominator) > 0.000_001 {
                    let xIntersection = (previous.x - current.x)
                        * (point.y - current.y) / denominator + current.x
                    if point.x < xIntersection { inside.toggle() }
                }
            }
            previous = current
        }
        return inside
    }

    nonisolated static func normalizedPageRect(
        forSliceRect rect: CGRect,
        sourceRect: CGRect
    ) -> CGRect {
        MangaPageCoordinateSpace.normalizedPageRect(
            forCropLocalRect: rect,
            cropRect: sourceRect
        )
    }
}
