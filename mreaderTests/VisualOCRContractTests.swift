import XCTest
@testable import mreader

final class VisualOCRContractTests: XCTestCase {
    func testRecognitionPromptRequestsLayoutSafeRegion() {
        let prompt = AITranslator.visionRecognitionPromptForDiagnostics(isRightToLeft: true)
        XCTAssertTrue(prompt.contains("layoutSafeRegion"))
        XCTAssertTrue(prompt.contains("coordinateSpace"))
        XCTAssertTrue(prompt.contains("sourceText"))
        XCTAssertTrue(prompt.contains("textBox"))
    }
}
