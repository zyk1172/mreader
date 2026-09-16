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
///
/// Guided-panel navigation is latency-sensitive: every in-page tap is rendered as
/// one continuous transaction. Earlier two-stage bridge + settle moves consumed a
/// second SwiftUI transaction and a MainActor wake-up, which could visibly pause
/// between stages when image/cache work landed at the same time.
nonisolated enum GuidedPanelMotionPlanner {
    static func profile(
        from source: CGRect?,
        to destination: CGRect?,
        crossesPageBoundary: Bool = false
    ) -> GuidedPanelMotionProfile {
        if crossesPageBoundary {
            return singleStageProfile(
                kind: .pageBoundary,
                duration: 0.58
            )
        }
        guard let source, let destination else {
            return singleStageProfile(
                kind: .focusEntry,
                duration: 0.52
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
            let duration = clamp(
                0.34 + Double(distance) * 0.18 + Double(scaleChange) * 0.03,
                0.36,
                0.46
            )
            return singleStageProfile(kind: .sameRow, duration: duration)
        }

        if distance >= 0.56 || scaleChange >= 1.8 {
            let duration = clamp(
                0.60 + Double(distance) * 0.16 + Double(scaleChange) * 0.03,
                0.62,
                0.76
            )
            return singleStageProfile(kind: .farJump, duration: duration)
        }

        let movesDownward = destination.midY > source.midY + 0.05
        if movesDownward, verticalOverlap < 0.32 {
            let duration = clamp(
                0.50 + Double(distance) * 0.16 + Double(scaleChange) * 0.03,
                0.52,
                0.62
            )
            return singleStageProfile(kind: .nextRow, duration: duration)
        }

        let duration = clamp(
            0.40 + Double(distance) * 0.18 + Double(scaleChange) * 0.03,
            0.42,
            0.52
        )
        return singleStageProfile(kind: .nearby, duration: duration)
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

    /// Retained as a pure geometry helper for compatibility with older tests/callers.
    /// Current guided-panel navigation deliberately does not use a context bridge.
    static func bridgeRect(from source: CGRect, to destination: CGRect) -> CGRect {
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let destinationCenter = CGPoint(x: destination.midX, y: destination.midY)
        let distance = hypot(
            destinationCenter.x - sourceCenter.x,
            destinationCenter.y - sourceCenter.y
        )
        let progress = min(max(0.12 + distance * 0.06, 0.12), 0.20)
        let rect = CGRect(
            x: source.minX + (destination.minX - source.minX) * progress,
            y: source.minY + (destination.minY - source.minY) * progress,
            width: source.width + (destination.width - source.width) * progress,
            height: source.height + (destination.height - source.height) * progress
        )
        return MangaPageCoordinateSpace.clampedNormalizedRect(rect)
    }

    private static func singleStageProfile(
        kind: GuidedPanelMotionKind,
        duration: TimeInterval
    ) -> GuidedPanelMotionProfile {
        GuidedPanelMotionProfile(
            kind: kind,
            duration: duration,
            bridgeDuration: 0,
            settleDuration: duration,
            usesContextBridge: false
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
