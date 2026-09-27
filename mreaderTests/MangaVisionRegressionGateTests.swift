import CoreGraphics
import CoreML
import Foundation
import UIKit
import XCTest
@testable import mreader

private struct MangaVisionRegressionCorpus: Decodable {
    struct Case: Decodable {
        let id: String
        let image: String
        let scale: Double
    }

    let schemaVersion: Int
    let revision: String
    let notes: String
    let cases: [Case]
}

@MainActor
final class MangaVisionRegressionGateTests: XCTestCase {
    func testBundledCalibrationIsRevisionedAndMatchesApprovedThresholds() {
        let profile = MangaVisionCalibrationProfile.bundled
        XCTAssertFalse(profile.revision.isEmpty)
        XCTAssertEqual(profile.revision, MangaVisionKoharuProductionIdentity.calibrationRevision)

        // Per-class operating points. These are hard filters read by PanelDetectionService,
        // so they must stay at or above the decoder's admission floor.
        XCTAssertEqual(profile.calibration(for: .panel).confidenceThreshold, 0.10)
        XCTAssertEqual(profile.calibration(for: .text).confidenceThreshold, 0.18)
        XCTAssertEqual(profile.calibration(for: .balloon).confidenceThreshold, 0.20)
        XCTAssertEqual(profile.calibration(for: .onomatopoeia).confidenceThreshold, 0.20)
        for type in MangaRegionType.allCases {
            XCTAssertGreaterThanOrEqual(
                profile.calibration(for: type).confidenceThreshold,
                MangaVisionKoharuDecoder.scoreThreshold,
                "\(type.rawValue) operating point is below the admission floor"
            )
        }

        // The panel operating point must not sit above PanelPostProcessor's relative floor,
        // otherwise that floor can never engage.
        XCTAssertLessThanOrEqual(profile.calibration(for: .panel).confidenceThreshold, 0.14)

        // Panel de-duplication is near-identity only, with a size floor so inset panels are
        // preserved for PanelDetectionService's own merge policy.
        XCTAssertEqual(profile.calibration(for: .panel).iouThreshold, 0.90)
        XCTAssertEqual(profile.calibration(for: .panel).containmentThreshold, 0.97)
        XCTAssertEqual(profile.calibration(for: .panel).minimumSizeRatio, CGFloat(0.82))
        XCTAssertEqual(profile.calibration(for: .text).iouThreshold, 0.58)
        XCTAssertEqual(profile.calibration(for: .balloon).iouThreshold, 0.62)
        XCTAssertEqual(profile.calibration(for: .onomatopoeia).iouThreshold, 0.58)
        XCTAssertNil(profile.calibration(for: .text).minimumSizeRatio)
    }

    func testPanelCalibrationPreservesInsetPanelsButCollapsesDuplicateRows() {
        let profile = MangaVisionCalibrationProfile.bundled
        let outer = MangaVisionRegion(
            type: .panel,
            normalizedRect: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90),
            confidence: 0.95
        )
        // A small frame nested inside a large one is a real inset panel.
        let inset = MangaVisionRegion(
            type: .panel,
            normalizedRect: CGRect(x: 0.20, y: 0.20, width: 0.20, height: 0.20),
            confidence: 0.60
        )
        XCTAssertEqual(profile.deduplicated([outer, inset], type: .panel).count, 2)

        // Two rows describing the same instance must still collapse.
        let duplicate = MangaVisionRegion(
            type: .panel,
            normalizedRect: CGRect(x: 0.052, y: 0.052, width: 0.898, height: 0.898),
            confidence: 0.55
        )
        XCTAssertEqual(profile.deduplicated([outer, duplicate], type: .panel).count, 1)

        // Adjacent panels that merely touch must never merge.
        let neighbour = MangaVisionRegion(
            type: .panel,
            normalizedRect: CGRect(x: 0.55, y: 0.05, width: 0.40, height: 0.90),
            confidence: 0.70
        )
        XCTAssertEqual(profile.deduplicated([outer, neighbour], type: .panel).count, 2)
    }

    func testCalibrationOnlyCoversBundledClasses() {
        let profile = MangaVisionCalibrationProfile.bundled
        XCTAssertEqual(Set(profile.byRegionType.keys), Set(MangaRegionType.allCases))
    }

    func testRawOutputContractHasFourClassRows() {
        XCTAssertEqual(
            MangaVisionKoharuClassOrder.labels,
            ["frame", "dialogue_text", "balloon", "onomatopoeia_text"]
        )
        XCTAssertEqual(MangaVisionKoharuOutputContract.inputSize, CGSize(width: 1280, height: 1280))
        XCTAssertEqual(MangaVisionKoharuOutputContract.detectionsShape, [1, 300, 38])
        XCTAssertEqual(MangaVisionKoharuOutputContract.protosShape, [1, 32, 320, 320])
    }

    func testBundledCompiledModelSatisfiesOutputContract() throws {
        let modelURL = try XCTUnwrap(bundledModelURL())
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let violations = MangaVisionKoharuOutputContract.validate(modelDescription: model.modelDescription)
        XCTAssertTrue(violations.isEmpty, "Bundled model contract violations: \(violations)")
    }

    func testManifestCacheIdentityUsesCurrentContractAndCalibrationRevisions() {
        let manifest = MangaVisionModelManifest.bundledKoharuYOLO26S(bundle: Bundle.main)
        XCTAssertEqual(manifest.outputContractRevision, MangaVisionKoharuOutputContract.revision)
        XCTAssertEqual(
            manifest.calibrationRevision,
            MangaVisionKoharuProductionIdentity.calibrationRevision
        )
        XCTAssertEqual(manifest.inputSize, MangaVisionKoharuPreprocessor.inputSize)
        XCTAssertEqual(manifest.semanticClasses, Set(MangaVisionKoharuClassOrder.regionTypes))
        XCTAssertFalse(manifest.cacheIdentity.isEmpty)
    }

    func testCacheIdentityChangesWhenTheSemanticContractChanges() {
        let manifest = MangaVisionModelManifest.bundledKoharuYOLO26S(bundle: Bundle.main)
        let narrower = MangaVisionModelManifest(
            modelID: manifest.modelID,
            modelVersion: manifest.modelVersion,
            modelBuildID: manifest.modelBuildID,
            modelFileHash: manifest.modelFileHash,
            inputSize: manifest.inputSize,
            semanticClasses: [.panel, .text],
            outputContractRevision: manifest.outputContractRevision,
            analysisSchemaRevision: manifest.analysisSchemaRevision,
            postProcessRevision: manifest.postProcessRevision,
            calibrationRevision: manifest.calibrationRevision
        )
        XCTAssertNotEqual(manifest.cacheIdentity, narrower.cacheIdentity)
    }

    func testRegressionMetricAggregationAndReleaseGate() {
        let rect = CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.20)
        let expected = [
            MangaVisionRegion(type: .panel, normalizedRect: rect, confidence: 1),
            MangaVisionRegion(type: .text, normalizedRect: rect.insetBy(dx: 0.05, dy: 0.05), confidence: 1),
            MangaVisionRegion(type: .balloon, normalizedRect: rect.insetBy(dx: 0.02, dy: 0.02), confidence: 1)
        ]
        let observation = MangaVisionRegressionObservation(
            expectedRegions: expected,
            predictedRegions: expected,
            expectedOCRRects: [rect],
            predictedOCRRects: [rect],
            usedFallback: false,
            inferenceCount: 2
        )
        let metrics = MangaVisionRegressionMetrics.aggregate([observation])
        XCTAssertEqual(metrics.panelRecall, 1)
        XCTAssertEqual(metrics.textRecall, 1)
        XCTAssertEqual(metrics.balloonRecall, 1)
        XCTAssertEqual(metrics.ocrFinalRecall, 1)
        XCTAssertEqual(metrics.fallbackRate, 0)
        XCTAssertEqual(metrics.inferenceCountPerPage, 2)
        XCTAssertTrue(MangaVisionRegressionGate.release.failures(for: metrics).isEmpty)
    }

    /// Stable across every source scale in the corpus.
    private static let minimumCorpusBalloonRecall = 0.95
    /// Measured 0.750. The bundled 1280px segmentation model loses one of the two
    /// shirohage panels below roughly 0.70x scale, which is a real, recorded property
    /// of this checkpoint rather than a pipeline defect. The floor exists to catch a
    /// regression, not to certify accuracy.
    private static let minimumCorpusPanelRecall = 0.70

    func testTwentyFourCaseBundledModelStabilityCorpus() async throws {
        let corpus: MangaVisionRegressionCorpus = try decodeFixture(
            "manga_vision_regression_corpus",
            extension: "json"
        )
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.cases.count, 24)
        XCTAssertFalse(corpus.revision.isEmpty)

        let provider = MangaVisionKoharuProvider()
        var observations: [MangaVisionRegressionObservation] = []
        for imageName in Set(corpus.cases.map(\.image)).sorted() {
            let sourceURL = try XCTUnwrap(fixtureURL(for: imageName))
            let sourceImage = try XCTUnwrap(UIImage(contentsOfFile: sourceURL.path))
            let sourceCG = try XCTUnwrap(sourceImage.cgImage)
            let sourceSize = CGSize(width: sourceCG.width, height: sourceCG.height)
            let imageCases = corpus.cases.filter { $0.image == imageName }
            let baselineCase = try XCTUnwrap(imageCases.first { abs($0.scale - 1) < 0.000_1 })
            let baselineImage = try XCTUnwrap(resized(sourceImage, scale: baselineCase.scale).cgImage)
            let baseline = try await provider.analyzePage(
                image: baselineImage,
                sourceImageSize: sourceSize,
                pageIdentifier: MangaPageIdentifier(
                    scope: "regression-baseline-\(imageName)",
                    pageIndex: 0,
                    sourceFingerprint: corpus.revision
                )
            )
            assertValidAnalysis(baseline)
            XCTAssertFalse(
                baseline.allRegions.isEmpty,
                "Bundled model returned no regions for \(imageName)"
            )

            for (index, item) in imageCases.enumerated() {
                let input = try XCTUnwrap(resized(sourceImage, scale: item.scale).cgImage)
                let analysis = try await provider.analyzePage(
                    image: input,
                    sourceImageSize: sourceSize,
                    pageIdentifier: MangaPageIdentifier(
                        scope: "regression-\(item.id)",
                        pageIndex: index,
                        sourceFingerprint: corpus.revision
                    )
                )
                assertValidAnalysis(analysis)
                observations.append(
                    MangaVisionRegressionObservation(
                        expectedRegions: baseline.allRegions,
                        predictedRegions: analysis.allRegions,
                        usedFallback: false,
                        inferenceCount: 1
                    )
                )
            }
        }

        XCTAssertEqual(observations.count, 24)
        let stability = MangaVisionRegressionMetrics.aggregate(
            observations,
            matchThreshold: 0.25
        )

        // This corpus has no human-verified labels: its "expected" set is the model's own
        // 1.0x output. `MangaVisionRegressionGate.release` is an *accuracy* policy that
        // only applies where verified expected regions exist, so the corpus gates on a
        // recorded stability floor instead. The release policy constants are asserted
        // separately below and are deliberately not tuned from this corpus.
        let balloonRecall = try XCTUnwrap(stability.balloonRecall)
        XCTAssertGreaterThanOrEqual(
            balloonRecall,
            Self.minimumCorpusBalloonRecall,
            "Balloon geometry must stay stable across source scale; metrics=\(stability)"
        )
        let panelRecall = try XCTUnwrap(stability.panelRecall)
        XCTAssertGreaterThanOrEqual(
            panelRecall,
            Self.minimumCorpusPanelRecall,
            "Panel stability regressed below the recorded floor; metrics=\(stability)"
        )
        XCTAssertEqual(stability.fallbackRate, 0)
        XCTAssertEqual(
            stability.inferenceCountPerPage,
            1,
            "Neither fixture is elongated enough to trigger refinement tiles"
        )
        XCTAssertLessThanOrEqual(
            stability.maximumInferenceCountOnPage,
            MangaVisionInferencePlanner.maximumInferencePassCount
        )
    }

    func testReleaseAccuracyPolicyIsUnchangedByTheStabilityCorpus() {
        // Guards against silently re-tuning the release policy to fit a corpus that has
        // no verified labels.
        let gate = MangaVisionRegressionGate.release
        XCTAssertEqual(gate.minimumPanelRecall, 0.80)
        XCTAssertEqual(gate.minimumTextRecall, 0.75)
        XCTAssertEqual(gate.minimumBalloonRecall, 0.70)
        XCTAssertEqual(gate.minimumOCRFinalRecall, 0.80)
        XCTAssertEqual(gate.maximumFallbackRate, 0.20)
        XCTAssertEqual(
            gate.maximumInferenceCountPerPage,
            Double(MangaVisionInferencePlanner.maximumInferencePassCount)
        )
    }

    private func assertValidAnalysis(
        _ analysis: MangaPageAnalysis,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(analysis.schemaVersion, MangaPageAnalysis.schemaVersion, file: file, line: line)
        XCTAssertEqual(
            analysis.modelIdentifier,
            MangaVisionKoharuProvider.modelIdentifier,
            file: file,
            line: line
        )
        for region in analysis.allRegions {
            let rect = region.normalizedRect
            XCTAssertTrue(rect.width > 0, file: file, line: line)
            XCTAssertTrue(rect.height > 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.minY, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxX, 1, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxY, 1, file: file, line: line)
            XCTAssertTrue(region.confidence.isFinite, file: file, line: line)
        }
    }

    private func bundledModelURL() -> URL? {
        let bundles = [Bundle.main, Bundle(for: MangaVisionRegressionGateTests.self)]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(
                forResource: MangaVisionKoharuProvider.modelResourceName,
                withExtension: "mlmodelc"
            ) {
                return url
            }
        }
        return nil
    }

    private func fixtureURL(for fileName: String) -> URL? {
        let file = URL(fileURLWithPath: fileName)
        let bundle = Bundle(for: MangaVisionRegressionGateTests.self)
        return bundle.url(
            forResource: file.deletingPathExtension().lastPathComponent,
            withExtension: file.pathExtension,
            subdirectory: "Fixtures"
        ) ?? bundle.url(
            forResource: file.deletingPathExtension().lastPathComponent,
            withExtension: file.pathExtension
        )
    }

    private func decodeFixture<T: Decodable>(
        _ name: String,
        extension fileExtension: String
    ) throws -> T {
        let bundle = Bundle(for: MangaVisionRegressionGateTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: fileExtension)
        )
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func resized(_ image: UIImage, scale: Double) -> UIImage {
        guard abs(scale - 1) > 0.000_1 else { return image }
        let target = CGSize(
            width: max(image.size.width * scale, 32),
            height: max(image.size.height * scale, 32)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
