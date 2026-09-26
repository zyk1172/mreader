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

    @Test func collisionResolverShrinksBeforeReturningAnOverlappingTranslation() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let original = CGRect(x: 10, y: 25, width: 80, height: 50)
        let occupied = [original]

        let placed = OCRBubbleLayoutEngine.collisionFreePlacement(
            original,
            scale: 0.5,
            anchor: CGPoint(x: original.midX, y: original.midY),
            occupiedRects: occupied,
            bounds: bounds,
            margin: 0
        )

        #expect(placed != nil)
        if let placed {
            #expect(bounds.contains(placed))
            #expect(!occupied.contains(where: { $0.intersects(placed) }))
            #expect(placed.width < original.width)
            #expect(placed.height < original.height)
        }
    }

    @Test func mappedBubbleContourUsesItsOwnBoundsAndPreservesEveryDisplayPoint() {
        let transform = OCRCoordinateMapper.displayTransform(
            sourcePixelSize: CGSize(width: 600, height: 1_000),
            containerSize: CGSize(width: 400, height: 400),
            fitMode: .fitScreen
        )
        let normalizedPoints = [
            CGPoint(x: 0.25, y: 0.25),
            CGPoint(x: 0.75, y: 0.25),
            CGPoint(x: 0.75, y: 0.75),
            CGPoint(x: 0.25, y: 0.75)
        ]

        let polygon = OCRCoordinateMapper.displayPolygon(
            forNormalizedPagePoints: normalizedPoints,
            using: transform,
            strokeOutset: 0
        )

        #expect(polygon != nil)
        if let polygon {
            #expect(polygon.rect == CGRect(x: 140, y: 100, width: 120, height: 200))
            for (normalized, local) in zip(normalizedPoints, polygon.localPoints) {
                let expected = OCRCoordinateMapper.displayPoint(
                    forNormalizedPagePoint: normalized,
                    using: transform
                )
                #expect(abs((polygon.rect.minX + local.x) - expected.x) < 0.0001)
                #expect(abs((polygon.rect.minY + local.y) - expected.y) < 0.0001)
            }
        }
    }

    @Test @MainActor func irregularBubbleLayoutShrinksInsideContourSafeArea() {
        let polygon = OCRDisplayPolygon(
            rect: CGRect(x: 20, y: 30, width: 100, height: 100),
            localPoints: [
                CGPoint(x: 50, y: 0),
                CGPoint(x: 100, y: 50),
                CGPoint(x: 50, y: 100),
                CGPoint(x: 0, y: 50)
            ]
        )

        let interior = OCRCoordinateMapper.interiorRect(for: polygon)

        #expect(interior != nil)
        guard let interior else { return }
        let halfDiagonal = interior.width / 2 + interior.height / 2
        #expect(halfDiagonal <= 50)

        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: "这是一段需要根据真实气泡轮廓自动缩小字号并完整显示的中文译文。",
            translationLines: [],
            sourceFontSize: 30,
            sourceRect: CGRect(
                x: interior.midX - 12,
                y: interior.midY - 12,
                width: 24,
                height: 24
            ),
            allowedBounds: interior,
            lineSpacing: 2,
            textOrientation: .horizontal,
            geometryStrategy: .detectedBubble,
            minimumReadableFontSize: 16
        )
        let contentSize = CGSize(
            width: max(choice.layout.rect.width - choice.layout.contentPadding * 2, 1),
            height: max(choice.layout.rect.height - choice.layout.contentPadding * 2, 1)
        )
        let measurement = TranslationTypesetter.measurement(
            text: choice.text,
            fontSize: choice.layout.fontSize,
            bounds: contentSize,
            orientation: .horizontal,
            lineSpacing: 2
        )

        #expect(interior.contains(choice.layout.rect))
        #expect(choice.layout.fontSize < 30)
        #expect(measurement.fitsAllText)
    }
}
