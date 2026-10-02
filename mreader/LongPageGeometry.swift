import CoreGraphics
import Foundation

/// Shared geometry only: these windows never become synthetic navigation panels.
nonisolated enum LongPageGeometry {
    static func windows(sourceSize: CGSize, maximumAspect: CGFloat = 2.5) -> [CGRect] {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return [] }
        let vertical = sourceSize.height >= sourceSize.width
        let aspect = max(sourceSize.width, sourceSize.height) / min(sourceSize.width, sourceSize.height)
        guard aspect > maximumAspect else { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
        let fraction = maximumAspect / aspect
        let count = Int(ceil((1 - fraction) / (fraction * 0.72))) + 1
        return (0..<count).map { index in
            let start = CGFloat(index) * (1 - fraction) / CGFloat(count - 1)
            return vertical ? CGRect(x: 0, y: start, width: 1, height: fraction)
                : CGRect(x: start, y: 0, width: fraction, height: 1)
        }
    }

    /// A long-side-only cap destroys strip width. Preserve the short axis as far
    /// as the explicit decoded-pixel budget allows; never allocate an unbounded strip.
    static func maximumPixelSize(sourceSize: CGSize, ordinaryMaximum: CGFloat,
                                 shortAxisTarget: CGFloat, maximumPixels: CGFloat) -> CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return ordinaryMaximum }
        let long = max(sourceSize.width, sourceSize.height)
        let short = min(sourceSize.width, sourceSize.height)
        let aspect = long / short
        guard aspect >= 3 else { return ordinaryMaximum }
        return min(long, min(shortAxisTarget * aspect, sqrt(maximumPixels * aspect)))
    }
}
