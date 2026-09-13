import XCTest
@testable import mreader

final class VisualOCRContractTests: XCTestCase {
    func testRecognitionPromptRequestsLayoutSafeRegion() {
        let prompt = AITranslator.visionRecognitionPromptForDiagnostics(isRightToLeft: true)
        XCTAssertTrue(prompt.contains("layoutSafeRegion"))
        XCTAssertTrue(prompt.contains("coordinateSpace"))
        XCTAssertTrue(prompt.contains("sourceText"))
        XCTAssertTrue(prompt.contains("textBox"))
        XCTAssertTrue(prompt.contains("bubbleBox 返回其区域，否则返回 null"))
        XCTAssertTrue(prompt.contains("textPolygon 无法可靠确定时返回 []"))
        XCTAssertTrue(prompt.contains("bubblePolygon 没有物理气泡或无法可靠确定时返回 []"))
    }
}
