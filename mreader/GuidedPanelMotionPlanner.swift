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
            // Page changes deliberately breathe longer than an in-page move. The
            // bridge exposes page context before the existing directional page
            // transition and the new page then performs its own focus entry.
            return GuidedPanelMotionProfile(
                kind: .pageBoundary,
                duration: 1.55,
                bridgeDuration: 0.68,
                settleDuration: 0.87,
                usesContextBridge: true
            )
        }
        guard let source, let destination else {
            return GuidedPanelMotionProfile(
                kind: .focusEntry,
                duration: 0.92,
                bridgeDuration: 0,
                settleDuration: 0.92,
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
            let duration = clamp(1.18 + Double(distance) * 0.20 + Double(scaleChange) * 0.035, 1.20, 1.32)
            let bridgeDuration = duration * 0.34
            return GuidedPanelMotionProfile(
                kind: .sameRow,
                duration: duration,
                bridgeDuration: bridgeDuration,
                settleDuration: duration - bridgeDuration,
                usesContextBridge: true
            )
        }

        if distance >= 0.56 || scaleChange >= 1.8 {
            let duration = clamp(1.48 + Double(distance) * 0.18 + Double(scaleChange) * 0.025, 1.54, 1.68)
            let bridgeDuration = duration * 0.31
            return GuidedPanelMotionProfile(
                kind: .farJump,
                duration: duration,
                bridgeDuration: bridgeDuration,
                settleDuration: duration - bridgeDuration,
                usesContextBridge: true
            )
        }

        let movesDownward = destination.midY > source.midY + 0.05
        if movesDownward, verticalOverlap < 0.32 {
            let duration = clamp(1.36 + Double(distance) * 0.18 + Double(scaleChange) * 0.03, 1.40, 1.54)
            let bridgeDuration = duration * 0.32
            return GuidedPanelMotionProfile(
                kind: .nextRow,
                duration: duration,
                bridgeDuration: bridgeDuration,
                settleDuration: duration - bridgeDuration,
                usesContextBridge: true
            )
        }

        let duration = clamp(1.28 + Double(distance) * 0.16 + Double(scaleChange) * 0.03, 1.30, 1.42)
        let bridgeDuration = duration * 0.33
        return GuidedPanelMotionProfile(
            kind: .nearby,
            duration: duration,
            bridgeDuration: bridgeDuration,
            settleDuration: duration - bridgeDuration,
            usesContextBridge: true
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
        // The first stage moves only a small fraction toward the destination.
        // ReaderView already follows it with the longer settle stage, so this
        // produces a joystick-like acceleration profile: a slow, visible launch
        // from the source followed by faster travel along the same path. Using an
        // interpolated rect rather than source.union(destination) also prevents
        // the old zoom-out/zoom-in detour that made direction hard to perceive.
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let destinationCenter = CGPoint(x: destination.midX, y: destination.midY)
        let distance = hypot(
            destinationCenter.x - sourceCenter.x,
            destinationCenter.y - sourceCenter.y
        )
        let progress = min(max(0.075 + distance * 0.035, 0.075), 0.11)
        let rect = CGRect(
            x: source.minX + (destination.minX - source.minX) * progress,
            y: source.minY + (destination.minY - source.minY) * progress,
            width: source.width + (destination.width - source.width) * progress,
            height: source.height + (destination.height - source.height) * progress
        )
        return MangaPageCoordinateSpace.clampedNormalizedRect(rect)
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
