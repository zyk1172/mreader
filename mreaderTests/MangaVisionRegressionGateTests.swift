import CoreGraphics
import Foundation
import XCTest
@testable import mreader

@MainActor
final class MangaVisionRegressionGateTests: XCTestCase {
    func testBundledCalibrationMatchesLayout4ValidationThresholds() {
        let profile = MangaVisionCalibrationProfile.bundled
        XCTAssertFalse(profile.revision.isEmpty)

        XCTAssertEqual(profile.calibration(for: .panel).confidenceThreshold, 0.05)
        XCTAssertEqual(profile.calibration(for: .panel).nmsIOUThreshold, 0.50)
        XCTAssertEqual(profile.calibration(for: .text).confidenceThreshold, 0.05)
        XCTAssertEqual(profile.calibration(for: .text).nmsIOUThreshold, 0.50)
        XCTAssertEqual(profile.calibration(for: .balloon).confidenceThreshold, 0.05)
        XCTAssertEqual(profile.calibration(for: .balloon).nmsIOUThreshold, 0.45)
        XCTAssertEqual(profile.calibration(for: .onomatopoeia).confidenceThreshold, 0.05)
        XCTAssertEqual(profile.calibration(for: .onomatopoeia).nmsIOUThreshold, 0.45)
        XCTAssertEqual(Set(profile.byRegionType.keys), Set(MangaRegionType.allCases))
    }

    func testLayout4RawOutputContractHasFourIndependentClassChannelsAndMaskPrototype() {
        XCTAssertEqual(MangaLayout4V1OutputContract.inputShape, [1, 3, 640, 640])
        XCTAssertEqual(MangaLayout4V1OutputContract.classCount, 4)
        XCTAssertEqual(MangaLayout4V1OutputContract.prototypeCount, 8)
        XCTAssertEqual(MangaLayout4V1OutputContract.specs.count, 13)
        XCTAssertEqual(
            MangaLayout4V1OutputContract.specs
                .filter { $0.role == "classification" }
                .map(\.channels),
            [4, 4, 4, 4]
        )
        XCTAssertEqual(
            MangaLayout4V1Class.allCases.map(\.semanticName),
            ["frame", "text", "balloon", "onomatopoeia"]
        )
    }

    func testManifestCacheIdentityUsesLayout4ContractAndSchemaRevision() {
        let manifest = MangaVisionModelManifest.bundledMangaLayout4V1(bundle: Bundle.main)
        XCTAssertEqual(manifest.modelID, MangaLayout4V1Provider.modelIdentifier)
        XCTAssertEqual(manifest.outputContractRevision, MangaLayout4V1OutputContract.revision)
        XCTAssertEqual(
            manifest.analysisSchemaRevision,
            "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)"
        )
        XCTAssertEqual(
            manifest.calibrationRevision,
            MangaLayout4V1ProductionIdentity.calibrationRevision
        )
        XCTAssertEqual(manifest.inputSize, MangaLayout4V1Preprocessor.inputSize)
        XCTAssertEqual(
            manifest.semanticClasses,
            Set([.panel, .text, .balloon, .onomatopoeia])
        )
        XCTAssertFalse(manifest.cacheIdentity.isEmpty)
    }

    func testRegressionMetricAggregationCoversAllFourLayout4Classes() {
        let rect = CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.20)
        let expected = [
            MangaVisionRegion(type: .panel, normalizedRect: rect, confidence: 1),
            MangaVisionRegion(
                type: .text,
                normalizedRect: rect.insetBy(dx: 0.05, dy: 0.05),
                confidence: 1
            ),
            MangaVisionRegion(
                type: .balloon,
                normalizedRect: rect.insetBy(dx: 0.02, dy: 0.02),
                confidence: 1
            ),
            MangaVisionRegion(
                type: .onomatopoeia,
                normalizedRect: CGRect(x: 0.55, y: 0.45, width: 0.18, height: 0.12),
                confidence: 1
            )
        ]
        let observation = MangaVisionRegressionObservation(
            expectedRegions: expected,
            predictedRegions: expected,
            expectedOCRRects: [rect],
            predictedOCRRects: [rect],
            inferenceCount: 2
        )

        let metrics = MangaVisionRegressionMetrics.aggregate([observation])
        XCTAssertEqual(metrics.panelRecall, 1)
        XCTAssertEqual(metrics.textRecall, 1)
        XCTAssertEqual(metrics.balloonRecall, 1)
        XCTAssertEqual(metrics.onomatopoeiaRecall, 1)
        XCTAssertEqual(metrics.ocrFinalRecall, 1)
        XCTAssertEqual(metrics.inferenceCountPerPage, 2)
        XCTAssertTrue(MangaVisionRegressionGate.release.failures(for: metrics).isEmpty)
    }

    func testReleaseGateRejectsMissingOnomatopoeiaAndPassBudgetViolation() {
        let sfx = MangaVisionRegion(
            type: .onomatopoeia,
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1),
            confidence: 1
        )
        let metrics = MangaVisionRegressionMetrics.aggregate([
            MangaVisionRegressionObservation(
                expectedRegions: [sfx],
                predictedRegions: [],
                inferenceCount: MangaVisionInferencePlanner.maximumInferencePassCount + 1
            )
        ])
        let failures = MangaVisionRegressionGate.release.failures(for: metrics)

        XCTAssertTrue(failures.contains { $0.hasPrefix("onomatopoeia-recall:") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("maximum-inference-count-on-page:") })
    }

    func testDomainCannotRepresentLegacyFaceOrBodyClasses() {
        XCTAssertEqual(
            MangaRegionType.allCases,
            [.panel, .text, .balloon, .onomatopoeia]
        )
        XCTAssertEqual(
            Set(MangaRegionType.allCases.map(\.rawValue)),
            Set(["panel", "text", "balloon", "onomatopoeia"])
        )
    }
}
