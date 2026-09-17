import CoreGraphics
import Testing
@testable import mreader

@Suite
struct TranslationOverlayCollisionTests {
    @Test func collisionResolverFindsAFreeSlotWhenOneExists() {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 500)
        let original = CGRect(x: 140, y: 180, width: 100, height: 54)
        let occupied = [
            CGRect(x: 132, y: 172, width: 116, height: 70),
            CGRect(x: 132, y: 110, width: 116, height: 60),
            CGRect(x: 132, y: 244, width: 116, height: 60)
        ]

        let result = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: CGPoint(x: original.midX, y: original.midY),
            occupiedRects: occupied,
            bounds: bounds,
            margin: 8
        )

        #expect(bounds.insetBy(dx: 8, dy: 8).contains(result))
        #expect(!occupied.contains(where: { $0.intersects(result) }))
    }

    @Test func collisionResolverIsDeterministic() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let original = CGRect(x: 100, y: 100, width: 90, height: 48)
        let occupied = [CGRect(x: 95, y: 95, width: 100, height: 58)]
        let anchor = CGPoint(x: original.midX, y: original.midY)

        let first = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: anchor,
            occupiedRects: occupied,
            bounds: bounds,
            margin: 4
        )
        let second = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: anchor,
            occupiedRects: occupied,
            bounds: bounds,
            margin: 4
        )

        #expect(first == second)
    }
}
