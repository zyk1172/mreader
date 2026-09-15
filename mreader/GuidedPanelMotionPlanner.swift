import CoreGraphics
import Foundation

nonisolated enum GuidedPanelMotionKind: String, Sendable, Equatable {
    case sameRow
    case nearby
    case nextRow
    case farJump
    case pageBoundary
    case focusEntry
}

nonisolated struct GuidedPanelMotionProfile: Sendable, Equatable {
    let kind: GuidedPanelMotionKind
    let duration: TimeInterval
    let bridgeDuration: TimeInterval
    let settleDuration: TimeInterval
    let usesContextBridge: Bool
}

nonisolated struct GuidedPanelViewportTuning: Sendable, Equatable {
    let contextPadding: CGFloat
    let maximumScale: CGFloat
}

/// Turns panel geometry into perceptible camera motion instead of applying one
/// fixed spring to every transition. The planner is pure so its behavior can be
/// regression-tested without SwiftUI or a device renderer.
nonisolated enum GuidedPanelMotionPlanner {
    static func profile(
        from source: CGRect?,
        to destination: CGRect?,
        crossesPageBoundary: Bool = false
    ) -> GuidedPanelMotionProfile {
        if crossesPageBoundary {
            // A page boundary still exposes page context before the directional
            // page transition. In-page moves deliberately do not use a bridge:
            // a single uninterrupted camera path is easier to track spatially.
            return GuidedPanelMotionProfile(
                kind: .pageBoundary,
                duration: 1.85,
                bridgeDuration: 0.82,
                settleDuration: 1.03,
                usesContextBridge: true
            )
        }
        guard let source, let destination else {
            return GuidedPanelMotionProfile(
                kind: .focusEntry,
                duration: 1.10,
                bridgeDuration: 0,
                settleDuration: 1.10,
                usesContextBridge: false
            )
        }

        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let destinationCenter = CGPoint(x: destination.midX, y: destination.midY)
        let distance = hypot(
            destinationCenter.x - sourceCenter.x,
            destinationCenter.y - sourceCenter.y
        )
        let verticalOverlap = overlapRatio(
            startA: source.minY,
            endA: source.maxY,
            startB: destination.minY,
            endB: destination.maxY
        )
        let scaleChange = abs(estimatedScale(for: destination) - estimatedScale(for: source))

        if verticalOverlap >= 0.48, abs(source.midY - destination.midY) <= 0.16 {
            let duration = clamp(1.34 + Double(distance) * 0.18 + Double(scaleChange) * 0.025, 1.35, 1.46)
            return GuidedPanelMotionProfile(
                kind: .sameRow,
                duration: duration,
                bridgeDuration: 0,
                settleDuration: duration,
                usesContextBridge: false
            )
        }

        if distance >= 0.56 || scaleChange >= 1.8 {
            let duration = clamp(1.68 + Double(distance) * 0.18 + Double(scaleChange) * 0.022, 1.72, 1.86)
            return GuidedPanelMotionProfile(
                kind: .farJump,
                duration: duration,
                bridgeDuration: 0,
                settleDuration: duration,
                usesContextBridge: false
            )
        }

        let movesDownward = destination.midY > source.midY + 0.05
        if movesDownward, verticalOverlap < 0.32 {
            let duration = clamp(1.52 + Double(distance) * 0.17 + Double(scaleChange) * 0.024, 1.56, 1.68)
            return GuidedPanelMotionProfile(
                kind: .nextRow,
                duration: duration,
                bridgeDuration: 0,
                settleDuration: duration,
                usesContextBridge: false
            )
        }

        let duration = clamp(1.44 + Double(distance) * 0.15 + Double(scaleChange) * 0.022, 1.46, 1.57)
        return GuidedPanelMotionProfile(
            kind: .nearby,
            duration: duration,
            bridgeDuration: 0,
            settleDuration: duration,
            usesContextBridge: false
        )
    }

    static func viewportTuning(for panel: CGRect) -> GuidedPanelViewportTuning {
        let area = max(panel.width, 0) * max(panel.height, 0)
        let shortSide = min(panel.width, panel.height)
        if area < 0.075 || shortSide < 0.18 {
            return GuidedPanelViewportTuning(contextPadding: 0.075, maximumScale: 4.8)
        }
        if area > 0.34 {
            return GuidedPanelViewportTuning(contextPadding: 0.060, maximumScale: 4.0)
        }
        return GuidedPanelViewportTuning(contextPadding: 0.068, maximumScale: 4.4)
    }

    static func bridgeRect(from source: CGRect, to destination: CGRect) -> CGRect {
        // Retained for page-context transitions and diagnostics. Ordinary
        // in-page motion no longer splits travel into bridge + settle stages.
        let union = source.union(destination)
        let dx = max(union.width * 0.06, 0.012)
        let dy = max(union.height * 0.06, 0.012)
        return MangaPageCoordinateSpace.clampedNormalizedRect(
            union.insetBy(dx: -dx, dy: -dy)
        )
    }

    private static func estimatedScale(for panel: CGRect) -> CGFloat {
        let safeWidth = max(panel.width, 0.04)
        let safeHeight = max(panel.height, 0.04)
        return min(1 / safeWidth, 1 / safeHeight, 4.8)
    }

    private static func overlapRatio(
        startA: CGFloat,
        endA: CGFloat,
        startB: CGFloat,
        endB: CGFloat
    ) -> CGFloat {
        let overlap = max(0, min(endA, endB) - max(startA, startB))
        let smaller = max(min(endA - startA, endB - startB), 0.0001)
        return overlap / smaller
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
