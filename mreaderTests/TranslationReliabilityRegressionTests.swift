import XCTest
@testable import mreader

final class TranslationReliabilityRegressionTests: XCTestCase {
    func testLineHintsCannotReplaceCanonicalTranslation() {
        let canonical = "不要走"
        let lines = TranslationOutputValidator.validatedTranslationLines(
            ["快走"],
            canonicalTranslation: canonical,
            sourceText: "行くな",
            target: .simplifiedChinese
        )
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(
            TranslationOutputValidator.validatedDisplayTranslation(
                canonicalTranslation: canonical,
                translationLines: ["快走"],
                sourceText: "行くな",
                target: .simplifiedChinese
            ),
            canonical
        )
    }

    func testNaturalDialogueContainingCannotIsAccepted() {
        XCTAssertTrue(
            TranslationOutputValidator.isAcceptableTranslation(
                "我不能放弃你",
                sourceText: "諦められない",
                target: .simplifiedChinese
            )
        )
    }

    func testStrictParserRejectsWholePageWrongLatinLanguage() throws {
        let expected = [
            AIPageTranslationItem(id: "b0", sourceText: "これはテストです", order: 0),
            AIPageTranslationItem(id: "b1", sourceText: "次の台詞です", order: 1)
        ]
        let payload = #"{"items":[{"id":"b0","translation":"Je suis très heureux de vous voir aujourd'hui.","translationLines":[]},{"id":"b1","translation":"Nous allons continuer cette conversation ensemble.","translationLines":[]}]}"#
            .replacingOccurrences(of: "\\\"", with: "\"")

        XCTAssertThrowsError(
            try AIPageTranslationParser.parseStrict(payload, expectedItems: expected, target: .english)
        ) { error in
            guard let parserError = error as? AIPageTranslationParserError else {
                XCTFail("Expected parser error, got \(error)")
                return
            }
            guard case .pageLanguageMismatch = parserError else {
                XCTFail("Expected pageLanguageMismatch, got \(parserError)")
                return
            }
        }
    }

    func testReadingOrderIsStableAcrossPermutationCounterexample() {
        let a = TextBlock(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
            text: "A",
            boundingBox: CGRect(x: 0.78, y: 0.18, width: 0.04, height: 0.04)
        )
        let b = TextBlock(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
            text: "B",
            boundingBox: CGRect(x: 0.48, y: 0.20, width: 0.04, height: 0.04)
        )
        let c = TextBlock(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
            text: "C",
            boundingBox: CGRect(x: 0.18, y: 0.22, width: 0.04, height: 0.04)
        )
        let permutations = [
            [a, b, c], [a, c, b], [b, a, c],
            [b, c, a], [c, a, b], [c, b, a]
        ]
        let outputs = permutations.map {
            AITranslator.sortedTextBlocks($0, isRightToLeft: false).map(\.id)
        }
        XCTAssertEqual(Set(outputs.map { $0.map(\.uuidString).joined(separator: ",") }).count, 1)
        XCTAssertEqual(outputs.first?.count, 3)
    }
}
