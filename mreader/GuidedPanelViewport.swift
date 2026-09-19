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


/// Builds a conservative content-aware focus inside an already-selected panel.
///
/// frame remains the only navigation target. text + balloon are the primary semantic
/// evidence for tightening a large panel's viewport. face/body can only expand an
/// already-established semantic focus, and body is ignored unless it is paired with a face.
/// This keeps the lower-accuracy person classes from creating navigation or focus targets.
nonisolated enum GuidedPanelSemanticViewportPlanner {
    private static let minimumPanelArea: CGFloat = 0.18
    private static let maximumPrimaryCoverage: CGFloat = 0.72
    private static let minimumFocusWidthFraction: CGFloat = 0.68
    private static let minimumFocusHeightFraction: CGFloat = 0.60
    private static let semanticPaddingFraction: CGFloat = 0.08
    private static let maximumUsefulFocusCoverage: CGFloat = 0.86

    private static let minimumFaceConfidence: Float = 0.45
    private static let minimumPersonConfidence: Float = 0.45
    private static let maximumAssistantAreaGrowth: CGFloat = 1.22
    private static let maximumAssistantPanelCoverage: CGFloat = 0.74

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

        var primaryByPanel: [UUID: [CGRect]] = [:]
        for region in analysis.balloons + analysis.texts {
            guard let owner = MangaSemanticAnalyzer.owningPanel(
                for: region.normalizedRect,
                panels: panelRegions
            ) else { continue }
            let clipped = clipped(region.normalizedRect, to: owner.normalizedRect)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            primaryByPanel[owner.id, default: []].append(clipped)
        }

        let people = MangaSemanticAnalyzer.personCandidates(
            faces: analysis.faces,
            bodies: analysis.bodies,
            panels: panelRegions
        )
        let peopleByPanel = Dictionary(grouping: people.compactMap { person -> MangaPersonCandidate? in
            guard person.panelID != nil else { return nil }
            return person
        }, by: { $0.panelID! })

        return panelRegions.map { panelRegion in
            focusRect(
                panel: panelRegion.normalizedRect,
                primaryRects: primaryByPanel[panelRegion.id] ?? [],
                people: peopleByPanel[panelRegion.id] ?? []
            )
        }
    }

    private static func focusRect(
        panel: CGRect,
        primaryRects: [CGRect],
        people: [MangaPersonCandidate]
    ) -> CGRect? {
        let panel = MangaPageCoordinateSpace.clampedNormalizedRect(panel)
        let panelArea = area(panel)
        guard panelArea >= minimumPanelArea, !primaryRects.isEmpty else { return nil }

        let primary = union(primaryRects)
        guard !primary.isNull, primary.width > 0, primary.height > 0 else { return nil }
        guard area(primary) / panelArea < maximumPrimaryCoverage else { return nil }

        var focus = contextualized(primary, within: panel)
        guard area(focus) / panelArea < maximumUsefulFocusCoverage else { return nil }

        // Person detections are deliberately weak evidence. A face/body result cannot create
        // a focus by itself. At most one high-confidence face candidate may protect nearby
        // character context from being cropped out; a body contributes only its upper section
        // and only when MangaSemanticAnalyzer has paired it with that face.
        let primaryCenter = CGPoint(x: primary.midX, y: primary.midY)
        let assistant = people
            .filter {
                guard let face = $0.face else { return false }
                return face.confidence >= minimumFaceConfidence
                    && $0.confidence >= minimumPersonConfidence
            }
            .min { lhs, rhs in
                assistantDistance(lhs, to: primaryCenter)
                    < assistantDistance(rhs, to: primaryCenter)
            }

        if let assistant,
           let assistantRect = assistantRect(for: assistant, clippedTo: panel) {
            let nearbyBounds = focus.insetBy(
                dx: -panel.width * 0.08,
                dy: -panel.height * 0.08
            ).intersection(panel)
            // A person hint may protect content immediately beside the primary viewport,
            // but a distant false-positive face must not recenter the camera.
            if nearbyBounds.intersects(assistantRect) {
                let candidate = contextualized(focus.union(assistantRect), within: panel)
                let growth = area(candidate) / max(area(focus), 0.000_001)
                let coverage = area(candidate) / panelArea
                if growth <= maximumAssistantAreaGrowth,
                   coverage <= maximumAssistantPanelCoverage {
                    focus = candidate
                }
            }
        }

        return area(focus) / panelArea < maximumUsefulFocusCoverage ? focus : nil
    }

    private static func assistantRect(
        for person: MangaPersonCandidate,
        clippedTo panel: CGRect
    ) -> CGRect? {
        guard let face = person.face else { return nil }
        var result = face.normalizedRect
        if let body = person.body {
            // Full body boxes are noisy in V2B5 and frequently much larger than the useful
            // portrait context. Only the upper body may softly extend a face-backed hint.
            let upperBody = CGRect(
                x: body.normalizedRect.minX,
                y: body.normalizedRect.minY,
                width: body.normalizedRect.width,
                height: body.normalizedRect.height * 0.38
            )
            result = result.union(upperBody)
        }
        let clipped = clipped(result, to: panel)
        return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? nil : clipped
    }

    private static func assistantDistance(
        _ person: MangaPersonCandidate,
        to point: CGPoint
    ) -> CGFloat {
        guard let face = person.face else { return .greatestFiniteMagnitude }
        return hypot(
            face.normalizedRect.midX - point.x,
            face.normalizedRect.midY - point.y
        )
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
        return CGRect(
            x: minX,
            y: minY,
            width: targetWidth,
            height: targetHeight
        )
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
