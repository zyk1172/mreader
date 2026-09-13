import XCTest
@testable import mreader

/// 审查 #3 / #6 的回归：
/// - Vision 原文真实性复核的“可疑判据”必须只在真正可疑时才触发；
/// - 自定义 Vision Prompt 模板缺协议锚点必须被提前发现并回退默认模板。
final class VisionSourceReviewTests: XCTestCase {

    private func block(
        _ text: String,
        confidence: Double = 0.9,
        rect: CGRect = CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.05),
        orientation: TextOrientation = .horizontal,
        ocrSource: String = "vision-model:dialogue"
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: rect,
            translation: "译文",
            confidence: confidence,
            ocrSource: ocrSource,
            textOrientation: orientation,
            layoutRole: .dialogue
        )
    }

    // MARK: - 可疑判据（审查 #3）

    func testCleanHighConfidencePageNeedsNoReview() {
        let blocks = [
            block("こんにちは", rect: CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.05)),
            block("ありがとう", rect: CGRect(x: 0.10, y: 0.40, width: 0.20, height: 0.05))
        ]

        XCTAssertTrue(
            AITranslator.visionSourceReviewRegionsForDiagnostics(blocks).isEmpty,
            "干净且高置信的页面不应产生任何复核请求"
        )
    }

    func testLowConfidenceBlockIsSelected() {
        let blocks = [block("こんにちは", confidence: 0.60)]

        let regions = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.reason, "low-confidence")
        XCTAssertEqual(regions.first?.blockID, blocks[0].id)
    }

    func testHeavilyOverlappingNeighborsAreBothSelected() {
        let shared = CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.06)
        let blocks = [
            block("こんにちは", rect: shared),
            block("こんばんは", rect: shared.offsetBy(dx: 0.002, dy: 0.001))
        ]

        let regions = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks)
        XCTAssertEqual(regions.count, 2, "大面积重叠意味着可能看错行/看错气泡，两侧都要复核")
        XCTAssertTrue(regions.allSatisfy { $0.reason == "overlap" })
    }

    func testGarbledTextIsSelected() {
        let blocks = [block("◆◆◆◆◆")]

        let regions = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks)
        XCTAssertEqual(regions.first?.reason, "garbled")
    }

    func testAnomalousGeometryIsSelected() {
        // 归一化越界 + 极端长宽比。
        let blocks = [block("こんにちは", rect: CGRect(x: 0.02, y: 0.10, width: 0.005, height: 0.90))]

        let regions = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks)
        XCTAssertEqual(regions.first?.reason, "geometry")
    }

    func testSliceMergedBlockIsSelected() {
        let blocks = [
            block("今日はいい天気", ocrSource: "vision-model:slice-merge:dialogue")
        ]

        let regions = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks)
        XCTAssertEqual(regions.first?.reason, "slice-overlap")
    }

    func testReviewRegionsAreCapped() {
        let blocks = (0..<10).map { index in
            block(
                "小字\(index)",
                confidence: 0.4,
                rect: CGRect(x: 0.05, y: 0.02 + CGFloat(index) * 0.05, width: 0.15, height: 0.04)
            )
        }

        let regions = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks)
        XCTAssertEqual(regions.count, AITranslator.VisionSourceReviewPolicy.maximumRegionCount)
        XCTAssertLessThanOrEqual(
            regions.count,
            blocks.count,
            "复核请求数必须被限制，不能让每页请求量翻倍"
        )
    }

    func testReviewRegionIsExpandedAndClampedToPage() {
        let blocks = [
            block("こんにちは", confidence: 0.5, rect: CGRect(x: 0.0, y: 0.0, width: 0.20, height: 0.05))
        ]

        let region = AITranslator.visionSourceReviewRegionsForDiagnostics(blocks).first
        let rect = try? XCTUnwrap(region?.sourceRect)
        XCTAssertEqual(rect?.minX ?? -1, 0, accuracy: 0.0001, "裁剪必须收敛在页面内")
        XCTAssertEqual(rect?.minY ?? -1, 0, accuracy: 0.0001)
    }

    // MARK: - sourceText 修正判据（审查 #3）

    func testIdenticalReviewTextKeepsOriginalSource() {
        XCTAssertNil(
            AITranslator.correctedVisionSourceTextForDiagnostics(
                original: "こんにちは",
                review: VisionRegionTextCandidate(text: "こんにちは", confidence: 0.99)
            ),
            "文字一致时保留原文，不产生无意义改写"
        )
    }

    func testGarbledOriginalIsReplacedByReadableReview() {
        let corrected = AITranslator.correctedVisionSourceTextForDiagnostics(
            original: "◆◆◆◆◆",
            review: VisionRegionTextCandidate(text: "こんにちは", confidence: 0.9)
        )
        XCTAssertEqual(corrected, "こんにちは")
    }

    func testWeakConflictingReviewDoesNotOverwriteSource() {
        XCTAssertNil(
            AITranslator.correctedVisionSourceTextForDiagnostics(
                original: "こんにちは",
                review: VisionRegionTextCandidate(text: "さようなら", confidence: 0.50)
            ),
            "复核置信度不足时不得用一个更差的猜测覆盖原文"
        )
    }

    func testStrongConflictingReviewOverwritesSource() {
        let corrected = AITranslator.correctedVisionSourceTextForDiagnostics(
            original: "こんにちは",
            review: VisionRegionTextCandidate(text: "さようなら", confidence: 0.92)
        )
        XCTAssertEqual(corrected, "さようなら")
    }

    func testRefusalTextIsNeverAcceptedAsSource() {
        XCTAssertNil(
            AITranslator.correctedVisionSourceTextForDiagnostics(
                original: "◆◆◆◆◆",
                review: VisionRegionTextCandidate(text: "无法识别图中文字", confidence: 0.99)
            )
        )
    }

    func testCorrectedBlockDropsStaleTranslation() {
        let original = block("◆◆◆◆◆")
        let corrected = AITranslator.visionSourceCorrectedBlockForDiagnostics(
            original: original,
            text: "こんにちは"
        )

        XCTAssertEqual(corrected.text, "こんにちは")
        XCTAssertNil(corrected.translation, "原文被修正后旧译文必须清空并只重译这一块")
        XCTAssertEqual(corrected.boundingBox, original.boundingBox)
        XCTAssertEqual(corrected.textOrientation, original.textOrientation)
        XCTAssertEqual(corrected.layoutRole, original.layoutRole)
    }

    // MARK: - 源语言冲突（审查 #3）

    func testLatinOnlyTextConflictsWithNonLatinSourcePreference() {
        XCTAssertTrue(
            AITranslator.visionSourceLanguageConflictsForDiagnostics("HELLO WORLD", preference: .japanese)
        )
        XCTAssertFalse(
            AITranslator.visionSourceLanguageConflictsForDiagnostics("こんにちは世界", preference: .japanese)
        )
        XCTAssertFalse(
            AITranslator.visionSourceLanguageConflictsForDiagnostics("HELLO WORLD", preference: nil)
        )
    }

    // MARK: - Vision Prompt 协议校验（审查 #6）

    func testDefaultVisionPromptSatisfiesContract() {
        XCTAssertTrue(
            AITranslator.visionPromptValidationForDiagnostics(
                AITranslator.defaultVisionTranslationPromptTemplate
            ).isUsable
        )
    }

    func testVisionPromptWithoutLanguagePlaceholderIsRejected() {
        let validation = AITranslator.visionPromptValidationForDiagnostics(
            "把漫画翻译一下，只输出 JSON。"
        )
        XCTAssertFalse(validation.isUsable)
        XCTAssertTrue(validation.issues.contains(.missingPlaceholder("{targetLanguage}")))
        XCTAssertTrue(validation.issues.contains(.missingPlaceholder("{readingOrder}")))
    }

    func testVisionPromptMissingProtocolFieldsIsRejected() {
        let template = """
        翻译为 {targetLanguage}，阅读顺序 {readingOrder}。
        只输出 {"coordinateSpace":"normalized","items":[{"sourceText":"原文"}]}
        """
        let validation = AITranslator.visionPromptValidationForDiagnostics(template)
        XCTAssertFalse(validation.isUsable)
        XCTAssertTrue(validation.issues.contains(.missingProtocolToken("textBox")))
        XCTAssertTrue(validation.issues.contains(.missingProtocolToken("bubbleBox")))
        XCTAssertTrue(validation.issues.contains(.missingProtocolToken("classification")))
    }

    func testEffectiveVisionPromptFallsBackToDefaultWhenInvalid() {
        let broken = "随便写点什么"
        XCTAssertEqual(
            AITranslator.VisionPromptContract.effectiveTemplate(broken),
            AITranslator.defaultVisionTranslationPromptTemplate
        )
        XCTAssertEqual(
            AITranslator.VisionPromptContract.effectiveTemplate(
                AITranslator.defaultVisionTranslationPromptTemplate
            ),
            AITranslator.defaultVisionTranslationPromptTemplate
        )
    }

    func testEmptyVisionPromptIsRejected() {
        let validation = AITranslator.visionPromptValidationForDiagnostics("   ")
        XCTAssertFalse(validation.isUsable)
        XCTAssertEqual(validation.issues, [.empty])
    }
}
