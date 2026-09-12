import CoreGraphics
import Foundation
import XCTest

final class TranslationQualityBenchmarkTests: XCTestCase {
    func testFixtureManifestOnlyMarksAnnotatedSamplesReady() throws {
        let bundle = Bundle(for: TranslationQualityBenchmarkTests.self)
        let manifestURL = try XCTUnwrap(
            bundle.url(
                forResource: "translation_quality_manifest",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? bundle.url(
                forResource: "translation_quality_manifest",
                withExtension: "json"
            )
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(TranslationQualityBenchmarkManifest.self, from: data)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertFalse(manifest.samples.isEmpty)
        XCTAssertTrue(manifest.samples.allSatisfy { !$0.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        let ready = manifest.samples.filter { $0.annotationStatus == .ready }
        XCTAssertFalse(ready.isEmpty)
        XCTAssertTrue(ready.allSatisfy { sample in
            guard let goldText = sample.goldText else { return false }
            return !goldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })

        let pending = try XCTUnwrap(manifest.samples.first { $0.id == "manga-page-publicdomainq" })
        XCTAssertEqual(pending.annotationStatus, .pending)
        XCTAssertNil(pending.goldText)
    }

    func testCERUsesCharactersAndIgnoresLayoutWhitespace() {
        XCTAssertEqual(
            TranslationQualityBenchmark.characterErrorRate(
                reference: "ノートを買った。",
                hypothesis: "ノートを買った。"
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TranslationQualityBenchmark.characterErrorRate(
                reference: "ノートを買った。",
                hypothesis: "ノートを売った。"
            ),
            0.125,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TranslationQualityBenchmark.characterErrorRate(
                reference: "ノートを\n買った。",
                hypothesis: "ノートを買った。"
            ),
            0,
            accuracy: 0.0001
        )
    }

    func testDetectionRecallDoesNotRewardDuplicatePredictions() {
        let truth = [
            region(id: "a", text: "A", x: 0.10, y: 0.10, width: 0.20, height: 0.10, order: 0),
            region(id: "b", text: "B", x: 0.60, y: 0.60, width: 0.20, height: 0.10, order: 1)
        ]
        let predictions = [
            TranslationBenchmarkPrediction(
                id: "p1",
                text: "A",
                rect: CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.10)
            ),
            TranslationBenchmarkPrediction(
                id: "p2",
                text: "A duplicate",
                rect: CGRect(x: 0.11, y: 0.10, width: 0.20, height: 0.10)
            )
        ]

        XCTAssertEqual(
            TranslationQualityBenchmark.detectionRecall(truth: truth, predictions: predictions),
            0.5,
            accuracy: 0.0001
        )
    }

    func testReadingOrderSeparatesCoverageFromPairwiseCorrectness() {
        let score = TranslationQualityBenchmark.readingOrderScore(
            referenceIDs: ["A", "B", "C"],
            predictedIDs: ["A", "C", "B"]
        )
        XCTAssertEqual(score.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(score.pairwiseAccuracy, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.combinedScore, 2.0 / 3.0, accuracy: 0.0001)

        let partial = TranslationQualityBenchmark.readingOrderScore(
            referenceIDs: ["A", "B", "C"],
            predictedIDs: ["A", "B"]
        )
        XCTAssertEqual(partial.coverage, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(partial.pairwiseAccuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(partial.combinedScore, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testTerminologyDriftUsesDominantVariantRatherThanSingleGoldenTranslation() {
        let rate = TranslationQualityBenchmark.terminologyDriftRate(
            occurrences: [
                .init(key: "senpai", translatedValue: "前辈"),
                .init(key: "senpai", translatedValue: "前辈"),
                .init(key: "senpai", translatedValue: "学长"),
                .init(key: "club", translatedValue: "社团"),
                .init(key: "club", translatedValue: "社团")
            ]
        )
        XCTAssertEqual(rate, 0.2, accuracy: 0.0001)
    }

    func testPartialRecoveryMeasuresTargetedRetryAndPreservesSuccessfulText() {
        let score = TranslationQualityBenchmark.partialRecoveryScore(
            totalItemCount: 10,
            expectedMissingIDs: ["b", "c"],
            retriedIDs: ["b", "c", "x"],
            recoveredIDs: ["b", "c"]
        )
        XCTAssertEqual(score.retryPrecision, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.recoveryRecall, 1, accuracy: 0.0001)
        XCTAssertEqual(score.finalCompleteness, 1, accuracy: 0.0001)

        XCTAssertTrue(
            TranslationQualityBenchmark.successfulTranslationsRemainStable(
                before: ["a": "不要走", "b": "待补译"],
                after: ["a": "不要走", "b": "别走"],
                excludingRecoveredIDs: ["b"]
            )
        )
        XCTAssertFalse(
            TranslationQualityBenchmark.successfulTranslationsRemainStable(
                before: ["a": "不要走", "b": "待补译"],
                after: ["a": "快走", "b": "别走"],
                excludingRecoveredIDs: ["b"]
            )
        )
    }

    func testLayoutMetricsExposeUnreadableOverflowAndEscapeSeparately() {
        let score = TranslationQualityBenchmark.layoutScore(
            observations: [
                .init(fontSize: 13, minimumReadableFontSize: 12, isFullyVisible: true, escapedAllowedBounds: false),
                .init(fontSize: 9, minimumReadableFontSize: 12, isFullyVisible: true, escapedAllowedBounds: false),
                .init(fontSize: 14, minimumReadableFontSize: 12, isFullyVisible: false, escapedAllowedBounds: true)
            ]
        )
        XCTAssertEqual(score.unreadableRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.overflowRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(score.escapedBoundsRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testPerformanceScoreUsesP50P95AndKeepsActualRequestCostCounters() {
        let score = TranslationQualityBenchmark.performanceScore(
            latenciesMilliseconds: [100, 120, 140, 160, 1000],
            requestCount: 7,
            estimatedCost: 0.031
        )
        XCTAssertEqual(score.p50Milliseconds, 140, accuracy: 0.0001)
        XCTAssertEqual(score.p95Milliseconds, 1000, accuracy: 0.0001)
        XCTAssertEqual(score.requestCount, 7)
        XCTAssertEqual(score.estimatedCost, 0.031, accuracy: 0.0001)
    }

    private func region(
        id: String,
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        order: Int
    ) -> TranslationBenchmarkRegion {
        TranslationBenchmarkRegion(
            id: id,
            text: text,
            rect: TranslationBenchmarkRect(x: x, y: y, width: width, height: height),
            readingOrder: order,
            bubbleID: nil
        )
    }
}
