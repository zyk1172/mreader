import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import ImageIO
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

    func testPythonGoldenFixturesPreserveFrozenContract() throws {
        let synthetic: SyntheticGoldenFixture = try decodeFixture("v2b5_synthetic")
        XCTAssertEqual(synthetic.inputSeed, 109)
        XCTAssertEqual(synthetic.inputShape, [1, 3, 640, 640])
        XCTAssertEqual(synthetic.classes, ["frame", "text", "face", "body", "balloon"])
        XCTAssertEqual(synthetic.calibrationRevision, "v2b5-calibration-v1")
        XCTAssertEqual(synthetic.maxDetections, 300)
        XCTAssertEqual(synthetic.rawOutputContract.count, 12)
        XCTAssertEqual(
            synthetic.rawOutputContract.map(\.tensor),
            [
                "p2_cls", "p2_bbox", "p2_centerness",
                "p3_cls", "p3_bbox", "p3_centerness",
                "p4_cls", "p4_bbox", "p4_centerness",
                "p5_cls", "p5_bbox", "p5_centerness"
            ]
        )
        XCTAssertEqual(MangaVisionV2B5Decoder.nmsThresholds, [0.50, 0.55, 0.45, 0.55, 0.45])
    }

    func testPythonGoldenRealValPageMatchesSwiftProvider() async throws {
        let fixture: RealGoldenFixture = try decodeFixture("v2b5_real_val")
        XCTAssertEqual(fixture.checkpointSHA256, "cb8947236e62bcf0fb516cd777886fce96f7cea52a29414d1408d0666edaf63f")
        XCTAssertEqual(fixture.calibrationRevision, "v2b5-calibration-v1")
        XCTAssertEqual(fixture.split, "val")
        XCTAssertEqual(fixture.classes, ["frame", "text", "face", "body", "balloon"])

        let imageURL = try XCTUnwrap(bundledResourceURL(named: fixture.page.bundledResource))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, fixture.page.width)
        XCTAssertEqual(image.height, fixture.page.height)
        let prepared = try MangaVisionV2B5Preprocessor.makeInput(from: image)
        let inputData = Data(
            bytes: UnsafeRawPointer(prepared.array.dataPointer),
            count: 1 * 3 * 640 * 640 * MemoryLayout<Float32>.stride
        )
        let swiftInputSHA = SHA256.hash(data: inputData)
            .map { String(format: "%02x", $0) }
            .joined()
        print("V2B5 golden input SHA python=\(fixture.inputSHA256) swift=\(swiftInputSHA) exact=\(swiftInputSHA == fixture.inputSHA256)")
        for (key, expected) in fixture.inputSamples.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            let actual = (0..<3).map {
                prepared.array[[0, $0, parts[1], parts[0]].map(NSNumber.init)].floatValue
            }
            for channel in 0..<min(expected.count, actual.count) {
                XCTAssertEqual(actual[channel], Float(expected[channel]), accuracy: 0.001, "input sample \(key) channel \(channel)")
            }
        }

        let identifier = MangaPageIdentifier(
            scope: "v2b5-python-swift-golden",
            pageIndex: 0,
            sourceFingerprint: fixture.page.filename
        )
        let analysis = try await MangaVisionV2B5Provider.shared.analyzePage(
            image: image,
            sourceImageSize: CGSize(width: image.width, height: image.height),
            pageIdentifier: identifier
        )

        for className in fixture.classes {
            let expected = fixture.detections.filter { $0.className == className }
            let actualType: MangaRegionType = switch className {
            case "frame": .panel
            case "text": .text
            case "face": .face
            case "body": .body
            case "balloon": .balloon
            default: throw GoldenFixtureError.unknownClass(className)
            }
            let actual = analysis.regions(of: actualType)
            XCTAssertEqual(actual.count, expected.count, className)
            var remaining = actual
            for item in expected {
                guard let bestIndex = remaining.indices.max(by: { lhs, rhs in
                    iou(remaining[lhs].normalizedRect, item.rect) < iou(remaining[rhs].normalizedRect, item.rect)
                }) else {
                    XCTFail("missing Swift detection for \(className)")
                    continue
                }
                let best = remaining.remove(at: bestIndex)
                XCTAssertGreaterThan(iou(best.normalizedRect, item.rect), 0.99, className)
                XCTAssertLessThan(abs(Double(best.confidence) - item.score), 0.02, className)
                XCTAssertNil(best.contour, className)
            }
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

        let reader = try MangaVisionV2B5TensorReader(
            array: p2Class,
            name: "test.p2_cls",
            expectedShape: [1, 5, 160, 160]
        )
        XCTAssertEqual(reader.value(channel: 4, y: y, x: x), 12, accuracy: 0.000_001)

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

    private func bundledResourceURL(named name: String) -> URL? {
        let resource = URL(fileURLWithPath: name)
        let bundles = [Bundle(for: Self.self), Bundle.main] + Bundle.allBundles
        return bundles.first { bundle in
            bundle.url(
                forResource: resource.deletingPathExtension().lastPathComponent,
                withExtension: resource.pathExtension
            ) != nil
        }?.url(
            forResource: resource.deletingPathExtension().lastPathComponent,
            withExtension: resource.pathExtension
        )
    }

    private func decodeFixture<T: Decodable>(_ name: String) throws -> T {
        let bundles = [Bundle(for: Self.self), Bundle.main] + Bundle.allBundles
        for bundle in bundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/v2b5_golden"
            ) ?? bundle.url(forResource: name, withExtension: "json") {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            }
        }
        throw GoldenFixtureError.fixtureMissing(name)
    }

    private func iou(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let area = max(intersection.width, 0) * max(intersection.height, 0)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - area
        return Double(area / max(union, 0.000_001))
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

private struct SyntheticGoldenFixture: Decodable {
    let inputSeed: Int
    let inputShape: [Int]
    let classes: [String]
    let calibrationRevision: String
    let maxDetections: Int
    let rawOutputContract: [SyntheticTensor]

    enum CodingKeys: String, CodingKey {
        case inputSeed = "input_seed"
        case inputShape = "input_shape"
        case classes
        case calibrationRevision = "calibration_revision"
        case maxDetections = "max_detections"
        case rawOutputContract = "raw_output_contract"
    }
}

private struct SyntheticTensor: Decodable {
    let tensor: String
}

private struct RealGoldenFixture: Decodable {
    let checkpointSHA256: String
    let calibrationRevision: String
    let classes: [String]
        let split: String
        let inputSHA256: String
        let page: RealGoldenPage
        let inputSamples: [String: [Double]]
    let detections: [RealGoldenDetection]

    enum CodingKeys: String, CodingKey {
        case checkpointSHA256 = "checkpoint_sha256"
        case calibrationRevision = "calibration_revision"
            case classes
            case split
            case inputSHA256 = "input_sha256"
            case inputSamples = "input_samples"
            case page
        case detections
    }
}

private struct RealGoldenPage: Decodable {
    let filename: String
    let bundledResource: String
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case filename
        case bundledResource = "bundled_resource"
        case width
        case height
    }
}

private struct RealGoldenDetection: Decodable {
    let className: String
    let score: Double
    let bbox: [Double]

    var rect: CGRect {
        CGRect(x: bbox[0], y: bbox[1], width: bbox[2] - bbox[0], height: bbox[3] - bbox[1])
    }

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case score
        case bbox
    }
}

private enum GoldenFixtureError: Error {
    case fixtureMissing(String)
    case unknownClass(String)
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
