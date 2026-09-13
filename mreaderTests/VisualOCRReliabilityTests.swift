import XCTest
@testable import mreader

final class VisualOCRReliabilityTests: XCTestCase {
    func testRegionTextParserAcceptsCoordinateFreeJSON() throws {
        let result = try XCTUnwrap(
            AITranslator.parseVisionRegionTextCandidateForDiagnostics(
                from: #"{"sourceText":"ウィキペディアに","confidence":0.93}"#
            )
        )

        XCTAssertEqual(result.text, "ウィキペディアに")
        XCTAssertEqual(result.confidence, 0.93, accuracy: 0.0001)
    }

    func testRegionTextParserAcceptsPlainTextFallback() throws {
        let result = try XCTUnwrap(
            AITranslator.parseVisionRegionTextCandidateForDiagnostics(from: "有名人です。")
        )

        XCTAssertEqual(result.text, "有名人です。")
        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.0001)
    }

    func testRegionTextParserRejectsVisionRefusalAsOCRText() {
        XCTAssertNil(
            AITranslator.parseVisionRegionTextCandidateForDiagnostics(from: "无法返回文本")
        )
        XCTAssertNil(
            AITranslator.parseVisionRegionTextCandidateForDiagnostics(
                from: "抱歉，我无法读取这张图片中的文字。"
            )
        )
    }

    func testTextFirstVisualReviewPreservesLocalOCRGeometry() {
        let original = TextBlock(
            text: "OEIIII",
            boundingBox: CGRect(x: 0.30, y: 0.20, width: 0.08, height: 0.24),
            confidence: 0.3,
            ocrSource: "original:manual",
            estimatedFontScale: 0.08,
            bubbleBox: CGRect(x: 0.28, y: 0.18, width: 0.14, height: 0.30),
            layoutSafeRegion: CGRect(x: 0.29, y: 0.19, width: 0.12, height: 0.28),
            textOrientation: .vertical,
            layoutRole: .dialogue
        )

        let reviewed = AITranslator.visualReviewedBlockForDiagnostics(
            original: original,
            review: VisionRegionTextCandidate(text: "ウィキペディアに", confidence: 0.91)
        )

        XCTAssertEqual(reviewed.text, "ウィキペディアに")
        XCTAssertEqual(reviewed.boundingBox, original.boundingBox)
        XCTAssertEqual(reviewed.bubbleBox, original.bubbleBox)
        XCTAssertEqual(reviewed.layoutSafeRegion, original.layoutSafeRegion)
        XCTAssertEqual(reviewed.textOrientation, original.textOrientation)
        XCTAssertEqual(reviewed.layoutRole, original.layoutRole)
        XCTAssertEqual(reviewed.ocrSource, "visual-review-text")
        XCTAssertFalse(reviewed.isFiltered)
    }

    func testVisionConnectionProbeAcceptsCodeReadFromImage() {
        XCTAssertTrue(AIVisionConnectionProbe.response("7KQ9XZ", contains: "7KQ9XZ"))
        XCTAssertTrue(AIVisionConnectionProbe.response("The code is: 7kq-9xz.", contains: "7KQ9XZ"))
    }

    func testVisionConnectionProbeRejectsTextOnlyOrWrongAnswers() {
        XCTAssertFalse(AIVisionConnectionProbe.response("OK", contains: "7KQ9XZ"))
        XCTAssertFalse(AIVisionConnectionProbe.response("无法读取图片", contains: "7KQ9XZ"))
        XCTAssertFalse(AIVisionConnectionProbe.response("7KQ9XY", contains: "7KQ9XZ"))
    }
}
