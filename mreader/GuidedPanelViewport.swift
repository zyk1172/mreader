import CoreGraphics

nonisolated struct GuidedPanelTransform: Sendable, Equatable {
    let scale: CGFloat
    let offset: CGSize
    let focusedRect: CGRect
}

/// Pure geometry for focusing a normalized panel while continuing to render the full page.
nonisolated enum GuidedPanelViewport {
    static let defaultContextPadding: CGFloat = 0.045
    static let defaultMaximumScale: CGFloat = 4.8

    static func transform(
        normalizedPanel: CGRect,
        imageAspectRatio: CGFloat,
        viewportSize: CGSize,
        contextPadding: CGFloat = defaultContextPadding,
        maximumScale: CGFloat = defaultMaximumScale
    ) -> GuidedPanelTransform {
        guard imageAspectRatio > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return GuidedPanelTransform(scale: 1, offset: .zero, focusedRect: .zero)
        }

        let paddedPanel = expandedAndClamped(
            normalizedPanel,
            contextPadding: contextPadding
        )
        let imageRect = aspectFitRect(
            aspectRatio: imageAspectRatio,
            in: CGRect(origin: .zero, size: viewportSize)
        )
        let focusedRect = CGRect(
            x: imageRect.minX + paddedPanel.minX * imageRect.width,
            y: imageRect.minY + paddedPanel.minY * imageRect.height,
            width: max(paddedPanel.width * imageRect.width, 1),
            height: max(paddedPanel.height * imageRect.height, 1)
        )

        let targetScale = min(
            viewportSize.width / focusedRect.width,
            viewportSize.height / focusedRect.height
        )
        let scale = min(max(targetScale, 1), max(maximumScale, 1))
        let viewportCenter = CGPoint(
            x: viewportSize.width / 2,
            y: viewportSize.height / 2
        )
        let offset = CGSize(
            width: (viewportCenter.x - focusedRect.midX) * scale,
            height: (viewportCenter.y - focusedRect.midY) * scale
        )
        return GuidedPanelTransform(
            scale: scale,
            offset: offset,
            focusedRect: focusedRect
        )
    }

    static func expandedAndClamped(
        _ rect: CGRect,
        contextPadding: CGFloat = defaultContextPadding
    ) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let source = rect.standardized.intersection(unit)
        guard !source.isNull, source.width > 0, source.height > 0 else {
            return unit
        }
        let padding = min(max(contextPadding, 0), 0.25)
        let dx = source.width * padding
        let dy = source.height * padding
        return source.insetBy(dx: -dx, dy: -dy).intersection(unit)
    }

    static func aspectFitRect(
        aspectRatio: CGFloat,
        in bounds: CGRect
    ) -> CGRect {
        guard aspectRatio > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return .zero
        }
        let boundsAspect = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio > boundsAspect {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
