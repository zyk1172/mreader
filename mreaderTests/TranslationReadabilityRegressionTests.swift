import XCTest
@testable import mreader

@MainActor
final class TranslationReadabilityRegressionTests: XCTestCase {
    func testVerticalTypesetterCanProveAllTextVisible() {
        let text = "「等等……！」第12回AI研究所"
        let measurement = TranslationTypesetter.measurement(
            text: text,
            fontSize: 18,
            bounds: CGSize(width: 320, height: 320),
            orientation: .vertical,
            lineSpacing: 2
        )
        XCTAssertEqual(measurement.visibleUTF16Length, (text as NSString).length)
        XCTAssertTrue(measurement.fitsAllText)
    }

    func testVerticalTypesetterDetectsActualOverflow() {
        let text = String(repeating: "漫画翻译", count: 12)
        let measurement = TranslationTypesetter.measurement(
            text: text,
            fontSize: 16,
            bounds: CGSize(width: 22, height: 22),
            orientation: .vertical,
            lineSpacing: 2
        )
        XCTAssertFalse(measurement.fitsAllText)
        XCTAssertLessThan(measurement.visibleUTF16Length, measurement.totalUTF16Length)
    }

    func testTinyBubbleStopsAtReadableFloorAndRequiresExpansion() {
        let floor: CGFloat = 12
        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: "这是一段明显无法塞进极小气泡但必须保留完整含义的长译文。",
            translationLines: [],
            sourceFontSize: 18,
            sourceRect: CGRect(x: 2, y: 2, width: 16, height: 16),
            allowedBounds: CGRect(x: 0, y: 0, width: 28, height: 28),
            lineSpacing: 2,
            textOrientation: .horizontal,
            geometryStrategy: .detectedBubble,
            minimumReadableFontSize: floor
        )
        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, floor)
        XCTAssertEqual(choice.layout.status, .needsExpansion)
    }

    func testVerticalTinyBubbleNeverFallsBackToMicroscopicText() {
        let floor: CGFloat = 11
        let choice = OCRBubbleLayoutEngine.preferredTranslationLayout(
            translation: "第一列第二列第三列第四列第五列",
            translationLines: [],
            sourceFontSize: 15,
            sourceRect: CGRect(x: 2, y: 2, width: 12, height: 18),
            allowedBounds: CGRect(x: 0, y: 0, width: 24, height: 30),
            lineSpacing: 2,
            textOrientation: .vertical,
            geometryStrategy: .detectedBubble,
            minimumReadableFontSize: floor
        )
        XCTAssertGreaterThanOrEqual(choice.layout.fontSize, floor)
        XCTAssertEqual(choice.layout.status, .needsExpansion)
    }

    func testCollisionAvoidanceCannotMoveDetectedBubbleOutsideItsBounds() {
        let bubble = CGRect(x: 10, y: 10, width: 120, height: 90)
        let original = CGRect(x: 35, y: 30, width: 60, height: 35)
        let occupied = [CGRect(x: 32, y: 27, width: 66, height: 41)]
        let resolved = OCRBubbleLayoutEngine.nonOverlappingRect(
            original,
            anchor: CGPoint(x: original.midX, y: original.midY),
            occupiedRects: occupied,
            bounds: bubble,
            margin: 0
        )
        XCTAssertTrue(bubble.insetBy(dx: -0.5, dy: -0.5).contains(resolved))
    }
}
