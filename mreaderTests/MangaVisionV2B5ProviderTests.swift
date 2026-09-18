import CoreGraphics
import CoreML
import Foundation
import XCTest
@testable import mreader

@MainActor
final class MangaVisionV2B5ProviderTests: XCTestCase {
    func testFrozenClassOrderAndCapabilities() {
        XCTAssertEqual(
            MangaVisionV2B5ClassOrder.labels,
            ["frame", "text", "face", "body", "balloon"]
        )
        XCTAssertEqual(
            MangaVisionV2B5ClassOrder.regionTypes,
            [.panel, .text, .face, .body, .balloon]
        )

        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: MangaVisionV2B5Provider.modelIdentifier,
            modelVersion: 5,
            inputSize: CGSize(width: 640, height: 640),
            supportedRegionTypes: Set(MangaVisionV2B5ClassOrder.regionTypes)
        )
        XCTAssertTrue(descriptor.capabilities.supportsFrame)
        XCTAssertTrue(descriptor.capabilities.supportsText)
        XCTAssertTrue(descriptor.capabilities.supportsFace)
        XCTAssertTrue(descriptor.capabilities.supportsBody)
        XCTAssertTrue(descriptor.capabilities.supportsBalloon)
        XCTAssertFalse(descriptor.capabilities.supportsBalloonMask)
    }

    func testOutputContractHasExplicitPyramidSemanticMapping() {
        XCTAssertEqual(MangaVisionV2B5OutputContract.specs.count, 12)
        XCTAssertEqual(
            MangaVisionV2B5OutputContract.specs.map(\.semanticName),
            [
                "p2_cls", "p2_bbox", "p2_centerness",
                "p3_cls", "p3_bbox", "p3_centerness",
                "p4_cls", "p4_bbox", "p4_centerness",
                "p5_cls", "p5_bbox", "p5_centerness"
            ]
        )
        XCTAssertEqual(
            MangaVisionV2B5OutputContract.specs.map(\.outputName),
            [
                "conv2d_77", "conv2d_78", "conv2d_79",
                "conv2d_88", "conv2d_89", "conv2d_90",
                "conv2d_99", "conv2d_100", "conv2d_101",
                "conv2d_110", "conv2d_111", "conv2d_112"
            ]
        )

        for level in ["p2", "p3", "p4", "p5"] {
            let levelSpecs = MangaVisionV2B5OutputContract.specs.filter { $0.level == level }
            XCTAssertEqual(levelSpecs.count, 3, "(level) must expose cls/bbox/centerness")
            XCTAssertEqual(Set(levelSpecs.map(\.role)), ["classification", "bbox", "centerness"])
        }
        XCTAssertEqual(MangaVisionV2B5OutputContract.spec(named: "p2_cls")?.channels, 5)
        XCTAssertEqual(MangaVisionV2B5OutputContract.spec(named: "p2_bbox")?.channels, 4)
        XCTAssertEqual(MangaVisionV2B5OutputContract.spec(named: "p2_centerness")?.channels, 1)
    }

    func testRawOutputMappingUsesNamesAndShapeContract() throws {
        var values: [String: MLMultiArray] = [:]
        for spec in MangaVisionV2B5OutputContract.specs.reversed() {
            let array = try MLMultiArray(
                shape: [1, spec.channels, spec.height, spec.width].map(NSNumber.init),
                dataType: .float32
            )
            values[spec.outputName] = array
        }
        let provider = FeatureProvider(values: values)
        let mapped = try MangaVisionV2B5OutputContract.rawOutputs(from: provider)

        XCTAssertEqual(Set(mapped.keys), MangaVisionV2B5OutputContract.outputNames)
        for spec in MangaVisionV2B5OutputContract.specs {
            XCTAssertEqual(
                mapped[spec.outputName]?.shape.map(\.intValue),
                [1, spec.channels, spec.height, spec.width],
                spec.semanticName
            )
        }
    }

    func testBundledModelDescriptionMatchesTheFrozenContract() throws {
        let modelURL = try XCTUnwrap(bundledModelURL())
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        XCTAssertTrue(
            MangaVisionV2B5OutputContract.validate(modelDescription: model.modelDescription).isEmpty
        )
    }

    func testDecoderMapsClassIndexFourToBalloonAndKeepsBoxCoordinates() throws {
        let raw = try makeRawOutputs()
        let p2Class = try XCTUnwrap(raw["conv2d_77"])
        let p2Center = try XCTUnwrap(raw["conv2d_79"])
        let p2BBox = try XCTUnwrap(raw["conv2d_78"])

        let x = 20
        let y = 30
        p2Class[[0, 4, y, x].map(NSNumber.init)] = NSNumber(value: 12)
        p2Center[[0, 0, y, x].map(NSNumber.init)] = NSNumber(value: 12)
        for channel in 0..<4 {
            p2BBox[[0, channel, y, x].map(NSNumber.init)] = NSNumber(value: 0)
        }

        let detections = try MangaVisionV2B5Decoder.decode(
            rawOutputs: raw,
            sourceSize: CGSize(width: 640, height: 640),
            letterbox: MangaVisionV2B5Letterbox.make(
                sourceSize: CGSize(width: 640, height: 640)
            )
        )

        let balloon = try XCTUnwrap(detections.first { $0.type == .balloon })
        XCTAssertEqual(balloon.pyramidLevel, "p2")
        XCTAssertGreaterThan(balloon.confidence, 0.99)
        XCTAssertEqual(balloon.normalizedRect.midX, (CGFloat(x) + 0.5) * 4 / 640, accuracy: 0.01)
        XCTAssertEqual(balloon.normalizedRect.midY, (CGFloat(y) + 0.5) * 4 / 640, accuracy: 0.01)
        XCTAssertTrue(balloon.normalizedRect.width > 0)
        XCTAssertTrue(balloon.normalizedRect.height > 0)
    }

    func testLetterboxUsesFrozenScaleRoundAndFloorPolicy() {
        let letterbox = MangaVisionV2B5Letterbox.make(
            sourceSize: CGSize(width: 1_280, height: 640)
        )
        XCTAssertEqual(letterbox.scale, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(letterbox.paddingXY.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(letterbox.paddingXY.y, 160, accuracy: 0.000_001)

        let source = letterbox.sourceNormalizedRect(
            fromInputRect: CGRect(x: 320, y: 240, width: 160, height: 80)
        )
        XCTAssertEqual(source.minX, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(source.minY, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(source.width, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(source.height, 0.25, accuracy: 0.000_001)
    }

    func testFrozenPostprocessConstantsIncludeBalloonNMS() {
        XCTAssertEqual(MangaVisionV2B5Decoder.scoreThreshold, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(MangaVisionV2B5Decoder.maxDetections, 300)
        XCTAssertEqual(MangaVisionV2B5Decoder.nmsThresholds, [0.50, 0.55, 0.45, 0.55, 0.45])
    }

    func testABComparatorReportsCrossClassFlipWithoutTreatingItAsSameClassMatch() {
        let identifier = MangaPageIdentifier(scope: "test", pageIndex: 0, sourceFingerprint: "fixture")
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2)
        let old = analysis(
            identifier: identifier,
            balloons: [MangaVisionRegion(type: .balloon, normalizedRect: rect, confidence: 0.9)]
        )
        let v2b5 = analysis(
            identifier: identifier,
            texts: [MangaVisionRegion(type: .text, normalizedRect: rect, confidence: 0.9)]
        )

        let comparison = MangaVisionABComparator.compare(old: old, v2b5: v2b5)
        XCTAssertEqual(comparison.matched, 0)
        XCTAssertEqual(comparison.oldOnly, 1)
        XCTAssertEqual(comparison.v2b5Only, 1)
        XCTAssertEqual(comparison.classFlips, 1)
    }

    private func makeRawOutputs() throws -> [String: MLMultiArray] {
        var result: [String: MLMultiArray] = [:]
        for spec in MangaVisionV2B5OutputContract.specs {
            let array = try MLMultiArray(
                shape: [1, spec.channels, spec.height, spec.width].map(NSNumber.init),
                dataType: .float32
            )
            for index in 0..<array.count {
                array[index] = NSNumber(value: spec.role == "bbox" ? 0 : -20)
            }
            result[spec.outputName] = array
        }
        return result
    }

    private func analysis(
        identifier: MangaPageIdentifier,
        texts: [MangaVisionRegion] = [],
        balloons: [MangaVisionRegion] = []
    ) -> MangaPageAnalysis {
        MangaPageAnalysis(
            pageIdentifier: identifier,
            imageSize: CGSize(width: 640, height: 640),
            panels: [],
            texts: texts,
            balloons: balloons,
            faces: [],
            bodies: [],
            modelIdentifier: "test",
            modelVersion: 1
        )
    }

    private func bundledModelURL() -> URL? {
        let bundles = [Bundle.main, Bundle(for: Self.self)] + Bundle.allBundles + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(forResource: MangaVisionV2B5Provider.modelResourceName, withExtension: "mlmodelc") {
                return url
            }
        }
        return nil
    }
}

private final class FeatureProvider: NSObject, MLFeatureProvider {
    let values: [String: MLMultiArray]

    init(values: [String: MLMultiArray]) {
        self.values = values
    }

    var featureNames: Set<String> { Set(values.keys) }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        values[featureName].map(MLFeatureValue.init(multiArray:))
    }
}
