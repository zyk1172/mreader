import CoreGraphics

/// Canonical coordinate conversion for Manga Vision and OCR ROI integration.
/// Business code only sees top-left normalized page coordinates.
nonisolated enum MangaPageCoordinateSpace {
    static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func clampedNormalizedRect(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite else {
            return .zero
        }
        let result = rect.standardized.intersection(unitRect)
        return result.isNull ? .zero : result
    }

    static func clampedNormalizedPoint(_ point: CGPoint) -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { return .zero }
        return CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }

    /// Vision observations use a bottom-left origin. All Manga Vision business
    /// coordinates use a top-left origin.
    static func topLeftNormalizedRect(fromVisionRect rect: CGRect) -> CGRect {
        clampedNormalizedRect(CGRect(
            x: rect.minX,
            y: 1 - rect.maxY,
            width: rect.width,
            height: rect.height
        ))
    }

    static func pixelRect(fromNormalized rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let normalized = clampedNormalizedRect(rect)
        return CGRect(
            x: normalized.minX * imageSize.width,
            y: normalized.minY * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        ).intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func normalizedRect(fromPixel rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return clampedNormalizedRect(CGRect(
            x: rect.minX / imageSize.width,
            y: rect.minY / imageSize.height,
            width: rect.width / imageSize.width,
            height: rect.height / imageSize.height
        ))
    }

    /// Maps xyxy coordinates produced in a square `.scaleFit` model input back
    /// onto the original page. The letterbox calculation is isolated here so
    /// reader/OCR code never needs to know model input dimensions.
    static func sourceNormalizedRectFromScaleFitXYXY(
        x1: CGFloat,
        y1: CGFloat,
        x2: CGFloat,
        y2: CGFloat,
        inputSize: CGSize,
        sourceSize: CGSize
    ) -> CGRect {
        guard inputSize.width > 0,
              inputSize.height > 0,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return .zero
        }
        let scale = min(inputSize.width / sourceSize.width, inputSize.height / sourceSize.height)
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let padX = (inputSize.width - scaledWidth) / 2
        let padY = (inputSize.height - scaledHeight) / 2
        return clampedNormalizedRect(CGRect(
            x: (x1 - padX) / scaledWidth,
            y: (y1 - padY) / scaledHeight,
            width: (x2 - x1) / scaledWidth,
            height: (y2 - y1) / scaledHeight
        ))
    }

    /// Maps one model-input point through the same `.scaleFit` letterbox used by
    /// the detection boxes. Points that fall in padding are rejected rather than
    /// clamped onto a page edge, which keeps mask contours from inventing geometry.
    static func sourceNormalizedPointFromScaleFitModelPoint(
        _ point: CGPoint,
        inputSize: CGSize,
        sourceSize: CGSize
    ) -> CGPoint? {
        guard inputSize.width > 0,
              inputSize.height > 0,
              sourceSize.width > 0,
              sourceSize.height > 0,
              point.x.isFinite,
              point.y.isFinite else {
            return nil
        }
        let scale = min(inputSize.width / sourceSize.width, inputSize.height / sourceSize.height)
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let padX = (inputSize.width - scaledWidth) / 2
        let padY = (inputSize.height - scaledHeight) / 2
        let normalized = CGPoint(
            x: (point.x - padX) / scaledWidth,
            y: (point.y - padY) / scaledHeight
        )
        guard normalized.x >= 0, normalized.x <= 1,
              normalized.y >= 0, normalized.y <= 1 else {
            return nil
        }
        return normalized
    }

    static func paddedNormalizedRect(_ rect: CGRect, fraction: CGFloat) -> CGRect {
        let source = clampedNormalizedRect(rect)
        guard source.width > 0, source.height > 0 else { return .zero }
        let safeFraction = min(max(fraction, 0), 0.30)
        return clampedNormalizedRect(source.insetBy(
            dx: -source.width * safeFraction,
            dy: -source.height * safeFraction
        ))
    }

    static func normalizedPageRect(forCropLocalRect rect: CGRect, cropRect: CGRect) -> CGRect {
        let crop = clampedNormalizedRect(cropRect)
        let local = clampedNormalizedRect(rect)
        return clampedNormalizedRect(CGRect(
            x: crop.minX + local.minX * crop.width,
            y: crop.minY + local.minY * crop.height,
            width: local.width * crop.width,
            height: local.height * crop.height
        ))
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let a = clampedNormalizedRect(lhs)
        let b = clampedNormalizedRect(rhs)
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = area(intersection)
        let union = area(a) + area(b) - intersectionArea
        return intersectionArea / max(union, 0.000_001)
    }

    static func containment(of inner: CGRect, in outer: CGRect) -> CGFloat {
        let innerRect = clampedNormalizedRect(inner)
        let intersection = innerRect.intersection(clampedNormalizedRect(outer))
        guard !intersection.isNull else { return 0 }
        return area(intersection) / max(area(innerRect), 0.000_001)
    }

    static func area(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }
}
