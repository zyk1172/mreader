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
        XCTAssertEqual(profile.calibration(for: .panel).confidenceThreshold, 0.24)
        XCTAssertEqual(profile.calibration(for: .panel).nmsIOUThreshold, 0.50)
        XCTAssertEqual(profile.calibration(for: .text).confidenceThreshold, 0.18)
        XCTAssertEqual(profile.calibration(for: .text).nmsIOUThreshold, 0.55)
        XCTAssertEqual(profile.calibration(for: .balloon).confidenceThreshold, 0.20)
        XCTAssertEqual(profile.calibration(for: .balloon).nmsIOUThreshold, 0.58)
        XCTAssertEqual(profile.calibration(for: .face).nmsIOUThreshold, 0.45)
        XCTAssertEqual(profile.calibration(for: .body).nmsIOUThreshold, 0.55)
    }

    func testDetectionOutputContractAcceptsBothSupportedTensorOrders() {
        let rowMajor = MangaVisionOutputContract.detectionTensorLayout(shape: [1, 300, 38])
        XCTAssertEqual(rowMajor?.rowMajor, true)
        XCTAssertEqual(rowMajor?.instanceCount, 300)
        XCTAssertEqual(rowMajor?.featureCount, 38)

        let featureMajor = MangaVisionOutputContract.detectionTensorLayout(shape: [1, 38, 300])
        XCTAssertEqual(featureMajor?.rowMajor, false)
        XCTAssertEqual(featureMajor?.instanceCount, 300)
        XCTAssertEqual(featureMajor?.featureCount, 38)

        XCTAssertNil(MangaVisionOutputContract.detectionTensorLayout(shape: [1, 5, 300]))
        XCTAssertNil(MangaVisionOutputContract.detectionTensorLayout(shape: [300, 38]))
        XCTAssertNil(MangaVisionOutputContract.detectionTensorLayout(shape: [2, 300, 38]))
    }

    func testBundledCompiledModelSatisfiesOutputContract() throws {
        let modelURL = try XCTUnwrap(bundledModelURL())
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let violations = MangaVisionOutputContract.validate(
            modelDescription: model.modelDescription,
            supportedRegionTypes: MangaVisionOutputContract.requiredSemanticClasses
        )
        XCTAssertTrue(violations.isEmpty, "Bundled model contract violations: \(violations)")

        if let creator = model.modelDescription.metadata[.creatorDefinedKey] {
            let labels = YOLOMangaVisionProvider.parseClassLabelsForDiagnostics(
                String(describing: creator)
            )
            if !labels.isEmpty {
                let normalized = Set(labels.values.map { $0.lowercased() })
                XCTAssertTrue(normalized.contains("frame") || normalized.contains("panel"))
                XCTAssertTrue(normalized.contains("text"))
                XCTAssertTrue(normalized.contains("balloon") || normalized.contains("bubble"))
            }
        }
    }

    func testManifestCacheIdentityUsesCurrentContractAndCalibrationRevisions() {
        let manifest = MangaVisionModelManifest.bundledPanelDetector(bundle: Bundle.main)
        XCTAssertEqual(manifest.outputContractRevision, MangaVisionOutputContract.revision)
        XCTAssertEqual(manifest.calibrationRevision, MangaVisionCalibrationProfile.bundled.revision)
        XCTAssertEqual(manifest.inputSize, MangaVisionOutputContract.expectedInputSize)
        XCTAssertEqual(manifest.semanticClasses, MangaVisionOutputContract.requiredSemanticClasses)
        XCTAssertFalse(manifest.cacheIdentity.isEmpty)
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

    func testTwentyFourCaseBundledModelStabilityCorpus() async throws {
        let corpus: MangaVisionRegressionCorpus = try decodeFixture(
            "manga_vision_regression_corpus",
            extension: "json"
        )
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.cases.count, 24)
        XCTAssertFalse(corpus.revision.isEmpty)

        let provider = YOLOMangaVisionProvider()
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
            matchThreshold: 0.35
        )
        let failures = MangaVisionRegressionGate.release.failures(for: stability)
        XCTAssertTrue(
            failures.isEmpty,
            "Manga Vision 24-case stability gate failed: \(failures); metrics=\(stability)"
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
            "manga109-yolo26s-seg-coreml-fp16-640-v2-manga-vision",
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
            if let url = bundle.url(forResource: "PanelDetector", withExtension: "mlmodelc") {
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
