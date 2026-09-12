import XCTest
@testable import mreader

final class TranslationOverflowRenderingContractTests: XCTestCase {
    func testCompactPreviewDoesNotUseLargeOriginalAssistBounds() {
        let allowed = CGRect(x: 0, y: 0, width: 390, height: 700)
        let source = CGRect(x: 40, y: 100, width: 260, height: 180)

        let preview = TranslationOverflowPresentationPolicy.compactPreviewRect(
            sourceRect: source,
            allowedBounds: allowed,
            orientation: .horizontal
        )

        XCTAssertLessThanOrEqual(preview.width, 120)
        XCTAssertLessThanOrEqual(preview.height, 56)
        XCTAssertTrue(allowed.contains(preview))
        XCTAssertLessThan(preview.width * preview.height, source.width * source.height * 0.2)
    }
}
