import XCTest

final class TranslationGoldReviewTests: XCTestCase {
    private let fixtureSHA1 = "8c828fc750e946ce94038a00782cbe115537c15e"

    func testCandidateCanBeStructurallyValidWithoutBecomingReportable() {
        let candidate = makeGold(
            verificationStatus: .candidate,
            expectedPageState: .unknown,
            review: nil
        )

        XCTAssertTrue(candidate.isInternallyConsistent)
        XCTAssertFalse(candidate.isReportableGold)
        XCTAssertEqual(
            TranslationGoldReviewValidator.reportabilityIssues(for: candidate),
            [.unresolvedPageState]
        )
    }

    func testHumanVerifiedGoldRequiresReviewReceipt() {
        let gold = makeGold(
            verificationStatus: .humanVerified,
            expectedPageState: .completed,
            review: nil
        )

        XCTAssertTrue(gold.isInternallyConsistent)
        XCTAssertFalse(gold.isReportableGold)
        XCTAssertTrue(
            TranslationGoldReviewValidator.reportabilityIssues(for: gold)
                .contains(.missingReviewReceipt)
        )
    }

    func testHumanVerifiedGoldWithPinnedImageReceiptBecomesReportable() {
        let gold = makeGold(
            verificationStatus: .humanVerified,
            expectedPageState: .completed,
            review: makeReview()
        )

        XCTAssertTrue(gold.isInternallyConsistent)
        XCTAssertTrue(
            TranslationGoldReviewValidator.reportabilityIssues(
                for: gold,
                expectedSourceImageSHA1: fixtureSHA1
            ).isEmpty
        )
        XCTAssertTrue(gold.isReportableGold)
    }

    func testPinnedImageMismatchPreventsTrustedReporting() {
        let gold = makeGold(
            verificationStatus: .humanVerified,
            expectedPageState: .completed,
            review: makeReview()
        )
        let wrongSHA1 = String(repeating: "0", count: 40)

        XCTAssertTrue(
            TranslationGoldReviewValidator.reportabilityIssues(
                for: gold,
                expectedSourceImageSHA1: wrongSHA1
            ).contains(.sourceImageMismatch)
        )
        XCTAssertThrowsError(
            try TranslationGoldBaselineScorer.score(
                gold: gold,
                baseline: makeBaseline(),
                expectedSourceImageSHA1: wrongSHA1
            )
        ) { error in
            XCTAssertEqual(error as? TranslationGoldScoringError, .goldNotReportable)
        }
    }

    func testStructuralValidationRejectsBrokenRegionContract() {
        let broken = TranslationBenchmarkPageGold(
            schemaVersion: 1,
            sampleID: "fixture",
            verificationStatus: .candidate,
            expectedPageState: .unknown,
            regions: [
                TranslationBenchmarkRegion(
                    id: "same",
                    text: "",
                    rect: TranslationBenchmarkRect(x: 0.9, y: 0.1, width: 0.2, height: 0.2),
                    readingOrder: 3,
                    bubbleID: ""
                ),
                TranslationBenchmarkRegion(
                    id: "same",
                    text: "二",
                    rect: TranslationBenchmarkRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    readingOrder: 3,
                    bubbleID: nil
                )
            ],
            referenceTranslations: ["missing": "translation"],
            notes: nil
        )

        let issues = TranslationGoldReviewValidator.structuralIssues(for: broken)
        XCTAssertTrue(issues.contains(.duplicateRegionID))
        XCTAssertTrue(issues.contains(.emptyRegionText))
        XCTAssertTrue(issues.contains(.invalidRegionRect))
        XCTAssertTrue(issues.contains(.invalidReadingOrder))
        XCTAssertTrue(issues.contains(.emptyBubbleID))
        XCTAssertTrue(issues.contains(.unknownReferenceTranslationRegion))
        XCTAssertFalse(broken.isInternallyConsistent)
    }

    func testTrustedScorerRejectsCandidateGold() {
        let candidate = makeGold(
            verificationStatus: .candidate,
            expectedPageState: .unknown,
            review: nil
        )

        XCTAssertThrowsError(
            try TranslationGoldBaselineScorer.score(
                gold: candidate,
                baseline: makeBaseline(),
                expectedSourceImageSHA1: fixtureSHA1
            )
        ) { error in
            XCTAssertEqual(error as? TranslationGoldScoringError, .goldNotReportable)
        }
    }

    func testTrustedScorerProducesPerfectMetricsForMatchingHumanGold() throws {
        let gold = makeGold(
            verificationStatus: .humanVerified,
            expectedPageState: .completed,
            review: makeReview()
        )
        let score = try TranslationGoldBaselineScorer.score(
            gold: gold,
            baseline: makeBaseline(),
            expectedSourceImageSHA1: fixtureSHA1
        )

        XCTAssertEqual(score.detectionRecall, 1, accuracy: 0.0001)
        XCTAssertEqual(score.meanRegionCER, 0, accuracy: 0.0001)
        XCTAssertEqual(score.readingOrder.pairwiseAccuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(score.readingOrder.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(score.grouping.sameBubbleRecall, 1, accuracy: 0.0001)
        XCTAssertEqual(score.grouping.crossBubbleFalseMergeRate, 0, accuracy: 0.0001)
        XCTAssertEqual(score.matchedRegionCount, 2)
        XCTAssertEqual(score.truthRegionCount, 2)
    }

    private func makeGold(
        verificationStatus: TranslationBenchmarkPageGold.VerificationStatus,
        expectedPageState: TranslationBenchmarkPageState,
        review: TranslationGoldReviewReceipt?
    ) -> TranslationBenchmarkPageGold {
        TranslationBenchmarkPageGold(
            schemaVersion: 1,
            sampleID: "fixture",
            verificationStatus: verificationStatus,
            expectedPageState: expectedPageState,
            regions: [
                TranslationBenchmarkRegion(
                    id: "region-001",
                    text: "一",
                    rect: TranslationBenchmarkRect(x: 0.7, y: 0.1, width: 0.1, height: 0.2),
                    readingOrder: 0,
                    bubbleID: "bubble-a"
                ),
                TranslationBenchmarkRegion(
                    id: "region-002",
                    text: "二",
                    rect: TranslationBenchmarkRect(x: 0.6, y: 0.1, width: 0.1, height: 0.2),
                    readingOrder: 1,
                    bubbleID: "bubble-a"
                )
            ],
            referenceTranslations: [
                "region-001": "one",
                "region-002": "two"
            ],
            review: review,
            notes: nil
        )
    }

    private func makeReview() -> TranslationGoldReviewReceipt {
        TranslationGoldReviewReceipt(
            reviewer: "human-reviewer",
            reviewedAt: "2026-09-13T04:00:00+08:00",
            method: .visualHumanReview,
            sourceImageSHA1: fixtureSHA1
        )
    }

    private func makeBaseline() -> TranslationFirstPageBaselineReport {
        let bubbleRect = TranslationBenchmarkRect(x: 0.55, y: 0.05, width: 0.3, height: 0.3)
        let first = TranslationBaselineBlock(
            id: "prediction-1",
            text: "一",
            rect: TranslationBenchmarkRect(x: 0.7, y: 0.1, width: 0.1, height: 0.2),
            confidence: 1,
            source: "test",
            orientation: "vertical",
            role: "dialogue",
            bubbleRect: bubbleRect,
            layoutSafeRegion: nil,
            filterReason: nil
        )
        let second = TranslationBaselineBlock(
            id: "prediction-2",
            text: "二",
            rect: TranslationBenchmarkRect(x: 0.6, y: 0.1, width: 0.1, height: 0.2),
            confidence: 1,
            source: "test",
            orientation: "vertical",
            role: "dialogue",
            bubbleRect: bubbleRect,
            layoutSafeRegion: nil,
            filterReason: nil
        )
        return TranslationFirstPageBaselineReport(
            schemaVersion: 2,
            sampleID: "fixture",
            capture: nil,
            detectedLanguage: "ja",
            elapsedMilliseconds: 1,
            rawCount: 2,
            resolvedCount: 2,
            lineCount: 2,
            bubbleBlockCount: 2,
            physicalBubbleCount: 1,
            rejectedCount: 0,
            quality: nil,
            lineBlocks: [first, second],
            bubbleBlocks: [first, second],
            rejectedBlocks: []
        )
    }
}
