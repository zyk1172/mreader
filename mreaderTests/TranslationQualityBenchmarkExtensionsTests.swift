import XCTest

final class TranslationQualityBenchmarkExtensionsTests: XCTestCase {
    func testGroupingScoreSeparatesMissedSameBubbleMergeFromCrossBubbleMerge() {
        let truth = [
            region(id: "a", order: 0, bubbleID: "bubble-1"),
            region(id: "b", order: 1, bubbleID: "bubble-1"),
            region(id: "c", order: 2, bubbleID: "bubble-2")
        ]

        let correct = TranslationQualityBenchmark.groupingScore(
            truth: truth,
            predictedGroups: [["a", "b"], ["c"]]
        )
        XCTAssertEqual(correct.sameBubbleRecall, 1, accuracy: 0.0001)
        XCTAssertEqual(correct.crossBubbleFalseMergeRate, 0, accuracy: 0.0001)
        XCTAssertEqual(correct.combinedScore, 1, accuracy: 0.0001)

        let overMerged = TranslationQualityBenchmark.groupingScore(
            truth: truth,
            predictedGroups: [["a", "b", "c"]]
        )
        XCTAssertEqual(overMerged.sameBubbleRecall, 1, accuracy: 0.0001)
        XCTAssertEqual(overMerged.crossBubbleFalseMergeRate, 1, accuracy: 0.0001)
        XCTAssertEqual(overMerged.combinedScore, 0.5, accuracy: 0.0001)

        let underMerged = TranslationQualityBenchmark.groupingScore(
            truth: truth,
            predictedGroups: [["a"], ["b"], ["c"]]
        )
        XCTAssertEqual(underMerged.sameBubbleRecall, 0, accuracy: 0.0001)
        XCTAssertEqual(underMerged.crossBubbleFalseMergeRate, 0, accuracy: 0.0001)
        XCTAssertEqual(underMerged.combinedScore, 0.5, accuracy: 0.0001)
    }

    func testNilBubbleRegionsRemainIndependentStructureTruth() {
        let truth = [
            region(id: "sfx", order: 0, bubbleID: nil),
            region(id: "caption", order: 1, bubbleID: nil)
        ]
        let score = TranslationQualityBenchmark.groupingScore(
            truth: truth,
            predictedGroups: [["sfx", "caption"]]
        )
        XCTAssertEqual(score.sameBubbleRecall, 1, accuracy: 0.0001)
        XCTAssertEqual(score.crossBubbleFalseMergeRate, 1, accuracy: 0.0001)
    }

    func testHumanReviewKeepsNaturalnessSeparateFromFidelityAndConsistency() throws {
        let score = TranslationQualityBenchmark.humanReviewScore(
            observations: [
                .init(fidelityPassed: true, consistencyPassed: true, naturalnessRating: 5),
                .init(fidelityPassed: true, consistencyPassed: false, naturalnessRating: 4),
                .init(fidelityPassed: false, consistencyPassed: true, naturalnessRating: 9)
            ]
        )
        XCTAssertEqual(score.fidelityPassRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.consistencyPassRate, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(score.meanNaturalnessRating), 4.5, accuracy: 0.0001)
        XCTAssertEqual(score.reviewCount, 3)
        XCTAssertEqual(score.ratedNaturalnessCount, 2)
    }

    func testCompletenessScoreExposesFalseNoTextSeparately() {
        let score = TranslationQualityBenchmark.completenessScore(
            observations: [
                .init(expected: .completed, actual: .completed),
                .init(expected: .partial, actual: .partial),
                .init(expected: .noText, actual: .noText),
                .init(expected: .partial, actual: .noText)
            ]
        )
        XCTAssertEqual(score.exactStateAccuracy, 0.75, accuracy: 0.0001)
        XCTAssertEqual(score.noTextFalsePositiveRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testCompletenessScoreIgnoresUnknownCandidateExpectations() {
        let score = TranslationQualityBenchmark.completenessScore(
            observations: [
                .init(expected: .unknown, actual: .completed),
                .init(expected: .unknown, actual: .noText),
                .init(expected: .completed, actual: .completed),
                .init(expected: .partial, actual: .noText)
            ]
        )

        XCTAssertEqual(score.exactStateAccuracy, 0.5, accuracy: 0.0001)
        XCTAssertEqual(score.noTextFalsePositiveRate, 0.5, accuracy: 0.0001)
    }

    private func region(
        id: String,
        order: Int,
        bubbleID: String?
    ) -> TranslationBenchmarkRegion {
        TranslationBenchmarkRegion(
            id: id,
            text: id,
            rect: TranslationBenchmarkRect(
                x: Double(order) * 0.2,
                y: 0.1,
                width: 0.1,
                height: 0.1
            ),
            readingOrder: order,
            bubbleID: bubbleID
        )
    }
}
