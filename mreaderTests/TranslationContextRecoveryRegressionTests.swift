import XCTest
@testable import mreader

@MainActor
final class TranslationContextRecoveryRegressionTests: XCTestCase {
    private func block(
        _ text: String,
        translation: String? = nil,
        x: CGFloat = 0.1,
        confidence: Double = 0.95,
        filtered: Bool = false,
        orientation: TextOrientation = .horizontal
    ) -> TextBlock {
        TextBlock(
            text: text,
            boundingBox: CGRect(x: x, y: 0.2, width: 0.12, height: 0.08),
            translation: translation,
            confidence: confidence,
            ocrSource: "test",
            isFiltered: filtered,
            filterReason: filtered ? "OCR质量可疑" : nil,
            estimatedFontScale: 0.04,
            textOrientation: orientation
        )
    }

    func testPagePromptPreservesGeometryOrderAndContextSemantics() throws {
        let item = AIPageTranslationItem(block: block("行くぞ"), order: 0)
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: [item],
            sourceLanguage: .japanese,
            target: .simplifiedChinese,
            styleInstructions: "自然对白",
            previousContext: "原文=兄さん → 译文=哥哥"
        )
        XCTAssertTrue(prompt.contains("\"order\":0"))
        XCTAssertTrue(prompt.contains("\"textBox\""))
        XCTAssertTrue(prompt.contains("称呼、术语、代词、语气"))
        XCTAssertTrue(prompt.contains("原文=兄さん → 译文=哥哥"))
        XCTAssertTrue(prompt.contains("不得凭空补人名"))
    }

    func testPagePromptRanksSourceAboveContextAndCarriesVisualMetadata() throws {
        let item = AIPageTranslationItem(
            id: "b0",
            sourceText: "彼は来ない",
            order: 0,
            boundingBox: CGRect(x: 0.55, y: 0.18, width: 0.10, height: 0.24),
            estimatedFontScale: 0.035,
            textOrientation: .vertical,
            layoutRole: .dialogue,
            bubbleBox: CGRect(x: 0.50, y: 0.12, width: 0.22, height: 0.38)
        )
        let prompt = try AIPageTranslationPromptBuilder.prompt(
            items: [item],
            sourceLanguage: .japanese,
            target: .simplifiedChinese,
            styleInstructions: AITranslator.defaultTranslationStyleInstructions,
            previousContext: "speakerHints=[person(x=0.7,y=0.3,score=0.4)]"
        )

        XCTAssertTrue(prompt.contains("当前 sourceText 与上下文冲突时，以当前 sourceText 为准"))
        XCTAssertTrue(prompt.contains("视觉位置、人物候选、说话人候选等弱提示"))
        XCTAssertTrue(prompt.contains(#""orientation":"vertical""#))
        XCTAssertTrue(prompt.contains(#""role":"dialogue""#))
        XCTAssertTrue(prompt.contains(#""bubbleBox":{"#))
        XCTAssertTrue(AITranslator.defaultTranslationStyleInstructions.contains("拟声词"))
        XCTAssertTrue(AITranslator.defaultTranslationStyleInstructions.contains("未确认的人物关系"))
    }

    func testSubsetRetryContextContainsAlreadyTranslatedNeighbours() {
        let blocks = [
            block("兄さん", translation: "哥哥", x: 0.1),
            block("どこへ行く？", x: 0.3)
        ]
        let context = TranslationContextBuilder.promptContext(
            previousContext: "",
            pageBlocks: blocks,
            requestedIndexes: [1]
        )
        XCTAssertTrue(context.contains("#1 [已译] 原文=兄さん | 译文=哥哥"))
        XCTAssertTrue(context.contains("#2 [待翻译] 原文=どこへ行く？"))
        XCTAssertTrue(context.contains("x=0.300"))
    }

    func testContextRegistryIsPageOrderedNotCompletionOrdered() async {
        let scope = "test-scope"
        await TranslationContextRegistry.shared.resetForDiagnostics()
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 1,
            blocks: [block("二", translation: "two")]
        )
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 0,
            blocks: [block("一", translation: "one")]
        )
        let first = await TranslationContextRegistry.shared.context(
            scopeID: scope,
            pageIndex: 2
        )
        await TranslationContextRegistry.shared.resetForDiagnostics()
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 0,
            blocks: [block("一", translation: "one")]
        )
        await TranslationContextRegistry.shared.record(
            scopeID: scope,
            pageIndex: 1,
            blocks: [block("二", translation: "two")]
        )
        let second = await TranslationContextRegistry.shared.context(
            scopeID: scope,
            pageIndex: 2
        )
        XCTAssertEqual(first, second)
        XCTAssertLessThan(first.range(of: "第1页")!.lowerBound, first.range(of: "第2页")!.lowerBound)
    }

    func testContextVersionChangesWithSemanticContent() {
        let first = TranslationContextBuilder.versionedContext(["原文=兄さん → 译文=哥哥"])
        let second = TranslationContextBuilder.versionedContext(["原文=姉さん → 译文=姐姐"])
        XCTAssertNotEqual(first.components(separatedBy: "\n").first, second.components(separatedBy: "\n").first)
    }

    func testVisualReviewIncludesRejectedAndVerticalCandidates() {
        let rejected = block("faint", x: 0.05, filtered: true)
        let vertical = block("縦書き", x: 0.30, orientation: .vertical)
        let stable = block("stable", x: 0.60)
        let regions = AITranslator.visualVerificationRegionsForDiagnostics(
            [stable, vertical, rejected],
            maximumCount: 6
        )
        let ids = Set(regions.map(\.blockID))
        XCTAssertTrue(ids.contains(rejected.id))
        XCTAssertTrue(ids.contains(vertical.id))
        XCTAssertFalse(ids.contains(stable.id))
        let verticalRegion = regions.first { $0.blockID == vertical.id }!
        XCTAssertGreaterThan(verticalRegion.sourceRect.width, vertical.boundingBox.width * 2)
    }
}
