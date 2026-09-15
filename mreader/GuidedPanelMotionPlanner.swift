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
            // 跨页不做“先退到整页上下文”的桥接：读者应该从上一页的最后一个分镜直接
            // 进入下一页的目标分镜，中间不出现整页画面。整段时长就是相机从旧取景
            // 移动到新取景的单次 easeInOut。
            return GuidedPanelMotionProfile(
                kind: .pageBoundary,
                duration: 0.85,
                bridgeDuration: 0,
                settleDuration: 0.85,
                usesContextBridge: false
            )
        }
        guard let source, let destination else {
            return GuidedPanelMotionProfile(
                kind: .focusEntry,
                duration: 1.00,
                bridgeDuration: 0,
                settleDuration: 1.00,
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
            // Same-row neighbours are the most frequent move in a page. They stay a
            // single stage: a bridge whose lead-in is a few percent of the distance
            // reads as "crawl, then jump" and doubles the transaction count for no
            // perceptible gain.
            let duration = clamp(0.90 + Double(distance) * 0.24 + Double(scaleChange) * 0.05, 0.92, 1.10)
            return GuidedPanelMotionProfile(
                kind: .sameRow,
                duration: duration,
                bridgeDuration: 0,
                settleDuration: duration,
                usesContextBridge: false
            )
        }

        if distance >= 0.56 || scaleChange >= 1.8 {
            let duration = clamp(1.20 + Double(distance) * 0.26 + Double(scaleChange) * 0.06, 1.22, 1.45)
            let bridgeDuration = duration * 0.30
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
            let duration = clamp(1.05 + Double(distance) * 0.22 + Double(scaleChange) * 0.06, 1.07, 1.25)
            let bridgeDuration = duration * 0.30
            return GuidedPanelMotionProfile(
                kind: .nextRow,
                duration: duration,
                bridgeDuration: bridgeDuration,
                settleDuration: duration - bridgeDuration,
                usesContextBridge: true
            )
        }

        let duration = clamp(0.95 + Double(distance) * 0.22 + Double(scaleChange) * 0.05, 0.97, 1.15)
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
        // The first stage moves a visible fraction toward the destination and the
        // longer settle stage covers the rest along the same path. The lead-in used
        // to travel only 7.5-11% of the way while consuming a third of the total
        // duration, which read as "crawl, stop, then jump". Keeping it at 12-20%
        // makes the two stages join into one accelerating camera move.
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
