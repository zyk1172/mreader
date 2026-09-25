import CoreGraphics
import Foundation

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


/// Builds a conservative content-aware focus inside an already-selected frame.
///
/// MangaLayout4 V1 frame detections are the only navigation targets. text, balloon and
/// onomatopoeia are semantic evidence that may tighten a large frame's viewport. No
/// legacy face/body/person path exists on this integration branch.
nonisolated enum GuidedPanelSemanticViewportPlanner {
    private static let minimumPanelArea: CGFloat = 0.18
    private static let maximumPrimaryCoverage: CGFloat = 0.72
    private static let minimumFocusWidthFraction: CGFloat = 0.68
    private static let minimumFocusHeightFraction: CGFloat = 0.60
    private static let semanticPaddingFraction: CGFloat = 0.08
    private static let maximumUsefulFocusCoverage: CGFloat = 0.86

    static func focusRects(
        panels: [CGRect],
        analysis: MangaPageAnalysis?
    ) -> [CGRect?] {
        guard !panels.isEmpty, let analysis else {
            return Array(repeating: nil, count: panels.count)
        }

        let panelRegions = panels.map {
            MangaVisionRegion(
                type: .panel,
                normalizedRect: MangaPageCoordinateSpace.clampedNormalizedRect($0),
                confidence: 1
            )
        }

        var semanticByPanel: [UUID: [CGRect]] = [:]
        for region in analysis.balloons + analysis.texts + analysis.onomatopoeias {
            guard let owner = MangaSemanticAnalyzer.owningPanel(
                for: region.normalizedRect,
                panels: panelRegions
            ) else { continue }
            let clipped = clipped(region.normalizedRect, to: owner.normalizedRect)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            semanticByPanel[owner.id, default: []].append(clipped)
        }

        return panelRegions.map { panelRegion in
            focusRect(
                panel: panelRegion.normalizedRect,
                primaryRects: semanticByPanel[panelRegion.id] ?? []
            )
        }
    }

    private static func focusRect(
        panel: CGRect,
        primaryRects: [CGRect]
    ) -> CGRect? {
        let panel = MangaPageCoordinateSpace.clampedNormalizedRect(panel)
        let panelArea = area(panel)
        guard panelArea >= minimumPanelArea, !primaryRects.isEmpty else { return nil }

        let primary = union(primaryRects)
        guard !primary.isNull, primary.width > 0, primary.height > 0 else { return nil }
        guard area(primary) / panelArea < maximumPrimaryCoverage else { return nil }

        let focus = contextualized(primary, within: panel)
        return area(focus) / panelArea < maximumUsefulFocusCoverage ? focus : nil
    }

    private static func contextualized(_ content: CGRect, within panel: CGRect) -> CGRect {
        let padded = content.insetBy(
            dx: -max(content.width * semanticPaddingFraction, panel.width * 0.035),
            dy: -max(content.height * semanticPaddingFraction, panel.height * 0.035)
        )
        let clipped = clipped(padded, to: panel)
        let targetWidth = min(
            panel.width,
            max(clipped.width, panel.width * minimumFocusWidthFraction)
        )
        let targetHeight = min(
            panel.height,
            max(clipped.height, panel.height * minimumFocusHeightFraction)
        )
        let center = CGPoint(x: content.midX, y: content.midY)
        let minX = min(
            max(center.x - targetWidth / 2, panel.minX),
            panel.maxX - targetWidth
        )
        let minY = min(
            max(center.y - targetHeight / 2, panel.minY),
            panel.maxY - targetHeight
        )
        return CGRect(x: minX, y: minY, width: targetWidth, height: targetHeight)
    }

    private static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    }

    private static func clipped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let intersection = MangaPageCoordinateSpace
            .clampedNormalizedRect(rect)
            .intersection(bounds)
        return intersection.isNull ? .null : intersection
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return max(rect.width, 0) * max(rect.height, 0)
    }
}
