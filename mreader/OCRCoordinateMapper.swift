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

    nonisolated static func normalizedPageRect(
        forSliceRect rect: CGRect,
        sourceRect: CGRect
    ) -> CGRect {
        CGRect(
            x: sourceRect.minX + rect.minX * sourceRect.width,
            y: sourceRect.minY + rect.minY * sourceRect.height,
            width: rect.width * sourceRect.width,
            height: rect.height * sourceRect.height
        )
    }
}
