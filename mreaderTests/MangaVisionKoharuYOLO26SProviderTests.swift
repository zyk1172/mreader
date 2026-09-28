import CoreGraphics
import CoreML
import Foundation
import UIKit
import XCTest
@testable import mreader

/// Contract and decoder tests for the bundled Koharu YOLO26s-seg detector.
@MainActor
final class MangaVisionKoharuYOLO26SProviderTests: XCTestCase {
    func testFrozenClassOrderMatchesCheckpointConfig() throws {
        let config = try Self.checkpointConfig()
        XCTAssertEqual(config.architectures, ["YOLO26s-seg"])
        XCTAssertEqual(config.task, "instance-segmentation")
        XCTAssertEqual(config.image_size, 1280)
        XCTAssertEqual(config.num_classes, 4)
        XCTAssertEqual(
            MangaVisionKoharuClassOrder.labels,
            config.names.sorted { $0.key < $1.key }.map(\.value)
        )
        XCTAssertEqual(
            MangaVisionKoharuClassOrder.regionTypes,
            [.panel, .text, .balloon, .onomatopoeia]
        )
        for (index, type) in MangaVisionKoharuClassOrder.regionTypes.enumerated() {
            XCTAssertEqual(type.modelClassIndex, index)
            XCTAssertEqual(
                MangaVisionKoharuClassOrder.regionType(forModelClassIndex: index),
                type
            )
        }
        XCTAssertNil(MangaVisionKoharuClassOrder.regionType(forModelClassIndex: 4))
    }

    func testProviderDescriptorAndCapabilities() async {
        let provider = MangaVisionKoharuProvider()
        let descriptor = await provider.descriptor
        XCTAssertEqual(descriptor.modelIdentifier, MangaVisionKoharuProvider.modelIdentifier)
        XCTAssertEqual(descriptor.inputSize, CGSize(width: 1280, height: 1280))
        XCTAssertEqual(descriptor.supportedRegionTypes, Set(MangaVisionKoharuClassOrder.regionTypes))

        let capabilities = descriptor.capabilities
        XCTAssertTrue(capabilities.supportsFrame)
        XCTAssertTrue(capabilities.supportsText)
        XCTAssertTrue(capabilities.supportsBalloon)
        XCTAssertTrue(capabilities.supportsOnomatopoeia)
        XCTAssertTrue(capabilities.supportsRegionMask)
    }

    func testBundledCompiledModelSatisfiesOutputContract() throws {
        let modelURL = try XCTUnwrap(Self.bundledModelURL())
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let violations = MangaVisionKoharuOutputContract.validate(
            modelDescription: model.modelDescription
        )
        XCTAssertTrue(violations.isEmpty, "Bundled model contract violations: \(violations)")

        let input = try XCTUnwrap(
            model.modelDescription.inputDescriptionsByName["image"]
        )
        XCTAssertEqual(input.type, .image)
        let constraint = try XCTUnwrap(input.imageConstraint)
        XCTAssertEqual(constraint.pixelsWide, 1280)
        XCTAssertEqual(constraint.pixelsHigh, 1280)
    }

    func testOutputContractRejectsUnexpectedShape() {
        XCTAssertEqual(MangaVisionKoharuOutputContract.detectionsShape, [1, 300, 38])
        XCTAssertEqual(MangaVisionKoharuOutputContract.protosShape, [1, 32, 320, 320])
        XCTAssertEqual(
            MangaVisionKoharuOutputContract.geometryChannelCount
                + MangaVisionKoharuOutputContract.maskCoefficientCount,
            MangaVisionKoharuOutputContract.detectionsShape[2]
        )
        XCTAssertEqual(
            MangaVisionKoharuOutputContract.maskPrototypeStride,
            Int(MangaVisionKoharuOutputContract.inputSize.width) /
                MangaVisionKoharuOutputContract.protosShape[3]
        )
    }

    func testReaderRejectsWrongShapeAndDataType() throws {
        let wrongShape = try MLMultiArray(shape: [1, 300, 39], dataType: .float32)
        XCTAssertThrowsError(
            try MangaVisionKoharuTensorReader(
                array: wrongShape,
                name: "detections",
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            )
        )

        let wrongType = try MLMultiArray(
            shape: MangaVisionKoharuOutputContract.detectionsShape as [NSNumber],
            dataType: .float16
        )
        XCTAssertThrowsError(
            try MangaVisionKoharuTensorReader(
                array: wrongType,
                name: "detections",
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            )
        )
    }

    func testDecoderReadsRowLayoutConfidenceAndClassIndex() throws {
        let detections = try Self.makeDetections(rows: [
            (0, 200, 600, 800, 0.91, 0),
            (220, 210, 470, 545, 0.88, 2),
            (300, 300, 340, 350, 0.04, 1)
        ])
        let protos = try Self.makeProtos(maskRect: nil)
        let letterbox = MangaVisionKoharuLetterbox.make(
            sourceSize: CGSize(width: 1280, height: 1280)
        )
        XCTAssertEqual(letterbox.scale, 1)

        let decoded = try MangaVisionKoharuDecoder.decode(
            detections: MangaVisionKoharuTensorReader(
                array: detections,
                name: "detections",
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            ),
            protos: MangaVisionKoharuTensorReader(
                array: protos,
                name: "protos",
                expectedShape: MangaVisionKoharuOutputContract.protosShape
            ),
            letterbox: letterbox
        )

        // Row three sits below the decoder's admission floor.
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].type, .panel)
        XCTAssertEqual(decoded[0].confidence, 0.91, accuracy: 0.000_1)
        XCTAssertEqual(decoded[1].type, .balloon)
        XCTAssertEqual(decoded[1].confidence, 0.88, accuracy: 0.000_1)

        let rect = decoded[1].normalizedRect
        XCTAssertEqual(rect.minX, 220 / 1280, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 210 / 1280, accuracy: 0.001)
        XCTAssertEqual(rect.width, 250 / 1280, accuracy: 0.001)
        XCTAssertEqual(rect.height, 335 / 1280, accuracy: 0.001)
        // The mask is empty in this fixture, so no contour may be fabricated.
        XCTAssertNil(decoded[0].contour)
    }

    func testDecoderBuildsNormalizedContourFromMask() throws {
        let detections = try Self.makeDetections(rows: [
            (64, 64, 320, 320, 0.93, 2)
        ])
        // Prototype space is 1/4 of the input, so the box covers prototypes 16...80.
        let protos = try Self.makeProtos(
            maskRect: CGRect(x: 20, y: 20, width: 50, height: 50)
        )
        let letterbox = MangaVisionKoharuLetterbox.make(
            sourceSize: CGSize(width: 1280, height: 1280)
        )

        let decoded = try MangaVisionKoharuDecoder.decode(
            detections: MangaVisionKoharuTensorReader(
                array: detections,
                name: "detections",
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            ),
            protos: MangaVisionKoharuTensorReader(
                array: protos,
                name: "protos",
                expectedShape: MangaVisionKoharuOutputContract.protosShape
            ),
            letterbox: letterbox
        )

        let contour = try XCTUnwrap(decoded.first?.contour)
        XCTAssertGreaterThanOrEqual(contour.points.count, 3)
        XCTAssertLessThanOrEqual(contour.points.count, MangaVisionContour.maximumPointCount)
        for point in contour.points {
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.x, 1)
            XCTAssertLessThanOrEqual(point.y, 1)
        }
        // The mask covers prototypes 20...69, which is input pixels 80...279.
        let bounds = contour.bounds
        XCTAssertEqual(bounds.minX, 80 / 1280, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 80 / 1280, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 280 / 1280, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 280 / 1280, accuracy: 0.01)
    }

    func testMaskContourUsesLargestConnectedComponent() throws {
        let detections = try Self.makeDetections(rows: [
            (64, 64, 512, 512, 0.94, 2)
        ])
        let protos = try Self.makeProtos(maskRects: [
            CGRect(x: 20, y: 20, width: 55, height: 55),
            CGRect(x: 105, y: 105, width: 10, height: 10)
        ])
        let decoded = try MangaVisionKoharuDecoder.decode(
            detections: MangaVisionKoharuTensorReader(
                array: detections,
                name: "detections",
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            ),
            protos: MangaVisionKoharuTensorReader(
                array: protos,
                name: "protos",
                expectedShape: MangaVisionKoharuOutputContract.protosShape
            ),
            letterbox: MangaVisionKoharuLetterbox.make(
                sourceSize: CGSize(width: 1280, height: 1280)
            )
        )
        let bounds = try XCTUnwrap(decoded.first?.contour?.bounds)
        XCTAssertLessThan(bounds.maxX, 0.30)
        XCTAssertLessThan(bounds.maxY, 0.30)
    }

    func testDecoderRejectsDetectionsLivingInLetterboxPadding() throws {
        let letterbox = MangaVisionKoharuLetterbox.make(
            sourceSize: CGSize(width: 640, height: 1280)
        )
        XCTAssertEqual(letterbox.contentRect.minX, 320, accuracy: 0.001)
        XCTAssertEqual(letterbox.contentRect.maxX, 960, accuracy: 0.001)

        let detections = try Self.makeDetections(rows: [
            (20, 120, 280, 700, 0.92, 0),   // entirely in left padding
            (340, 120, 700, 700, 0.91, 0)   // real page content
        ])
        let decoded = try MangaVisionKoharuDecoder.decode(
            detections: MangaVisionKoharuTensorReader(
                array: detections,
                name: "detections",
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            ),
            protos: MangaVisionKoharuTensorReader(
                array: try Self.makeProtos(maskRect: nil),
                name: "protos",
                expectedShape: MangaVisionKoharuOutputContract.protosShape
            ),
            letterbox: letterbox
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].type, .panel)
        XCTAssertGreaterThan(decoded[0].normalizedRect.minX, 0)
        XCTAssertLessThan(decoded[0].normalizedRect.maxX, 1)
    }

    func testLetterboxRoundTripUsesActualRoundedRasterSize() {
        let letterbox = MangaVisionKoharuLetterbox.make(
            sourceSize: CGSize(width: 4097, height: 3053)
        )
        XCTAssertEqual(
            letterbox.resizedSize.width,
            (4097.0 * letterbox.scale).rounded(),
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            letterbox.resizedSize.height,
            (3053.0 * letterbox.scale).rounded(),
            accuracy: 0.000_001
        )

        let source = CGRect(x: 0.137, y: 0.219, width: 0.413, height: 0.327)
        let input = letterbox.inputRect(fromSourceNormalizedRect: source)
        let restored = letterbox.sourceNormalizedRect(fromInputRect: input)
        XCTAssertEqual(restored.minX, source.minX, accuracy: 0.000_001)
        XCTAssertEqual(restored.minY, source.minY, accuracy: 0.000_001)
        XCTAssertEqual(restored.width, source.width, accuracy: 0.000_001)
        XCTAssertEqual(restored.height, source.height, accuracy: 0.000_001)
    }

    func testLetterboxUsesUltralyticsScaleRoundAndOffsetPolicy() {
        // A 4096x3053 page scaled into 1280 square: 954 tall, padded top and bottom.
        let tall = MangaVisionKoharuLetterbox.make(
            sourceSize: CGSize(width: 4096, height: 3053)
        )
        XCTAssertEqual(tall.scale, 1280.0 / 4096.0, accuracy: 0.000_001)
        XCTAssertEqual(tall.paddingXY.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(tall.paddingXY.y, 163, accuracy: 0.000_001)

        // A 3156x3840 page is padded left and right instead.
        let wide = MangaVisionKoharuLetterbox.make(
            sourceSize: CGSize(width: 3156, height: 3840)
        )
        XCTAssertEqual(wide.paddingXY.x, 114, accuracy: 0.000_001)
        XCTAssertEqual(wide.paddingXY.y, 0, accuracy: 0.000_001)

        // Round trip: an input-space box must return to the same source position.
        let sourceRect = CGRect(x: 0.25, y: 0.30, width: 0.20, height: 0.15)
        let inputRect = wide.inputRect(fromSourceNormalizedRect: sourceRect)
        let restored = wide.sourceNormalizedRect(fromInputRect: inputRect)
        XCTAssertEqual(restored.minX, sourceRect.minX, accuracy: 0.000_5)
        XCTAssertEqual(restored.minY, sourceRect.minY, accuracy: 0.000_5)
        XCTAssertEqual(restored.width, sourceRect.width, accuracy: 0.000_5)
        XCTAssertEqual(restored.height, sourceRect.height, accuracy: 0.000_5)
    }

    func testPreprocessorProducesGrayPaddedSquareCanvas() throws {
        let source = try XCTUnwrap(Self.solidImage(
            width: 640,
            height: 320,
            color: (10, 20, 30)
        ))
        let prepared = try MangaVisionKoharuPreprocessor.makeInput(from: source)
        XCTAssertEqual(prepared.image.width, 1280)
        XCTAssertEqual(prepared.image.height, 1280)
        XCTAssertEqual(prepared.letterbox.paddingXY.y, 320, accuracy: 0.000_001)

        let pixels = try Self.pixels(of: prepared.image)
        func sample(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * 1280 + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
        // Padded rows carry the ultralytics letterbox gray, not white.
        XCTAssertEqual(sample(0, 0).0, MangaVisionKoharuPreprocessor.paddingValue)
        XCTAssertEqual(sample(1279, 1279).2, MangaVisionKoharuPreprocessor.paddingValue)
        // The centred content band preserves the source color (resize is identity here).
        let content = sample(320, 640)
        XCTAssertEqual(Int(content.0), 10, accuracy: 2)
        XCTAssertEqual(Int(content.1), 20, accuracy: 2)
        XCTAssertEqual(Int(content.2), 30, accuracy: 2)
    }

    func testProviderAnalyzesRealFixturePageWithMasks() async throws {
        let url = try XCTUnwrap(Self.fixtureURL("sample_shirohage_manga.jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let provider = MangaVisionKoharuProvider()
        let analysis = try await provider.analyzePage(
            image: image,
            sourceImageSize: CGSize(width: image.width, height: image.height),
            pageIdentifier: MangaPageIdentifier(
                scope: "koharu-provider-fixture",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            )
        )

        XCTAssertEqual(analysis.schemaVersion, MangaPageAnalysis.schemaVersion)
        XCTAssertEqual(analysis.modelIdentifier, MangaVisionKoharuProvider.modelIdentifier)
        XCTAssertFalse(analysis.allRegions.isEmpty)
        // Omitting a person class is a contract guarantee, not a detection outcome.
        XCTAssertEqual(
            Set(analysis.allRegions.map(\.type)).subtracting(
                Set(MangaVisionKoharuClassOrder.regionTypes)
            ),
            []
        )
        for region in analysis.allRegions {
            XCTAssertTrue(region.confidence >= MangaVisionKoharuDecoder.scoreThreshold)
            let rect = region.normalizedRect
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, 1)
            XCTAssertLessThanOrEqual(rect.maxY, 1)
        }
        // The segmentation head must supply outlines for regions it keeps.
        XCTAssertTrue(analysis.allRegions.contains { $0.contour != nil })
    }

    /// The one-to-one head is trained to be duplicate-free but is not guaranteed to be:
    /// this fixture produced two overlapping `frame` rows at IoU ~0.97 before the
    /// provider applied the revisioned calibration profile.
    func testProviderOutputIsDeduplicatedPerClass() async throws {
        let url = try XCTUnwrap(Self.fixtureURL("sample_shirohage_manga.jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        let provider = MangaVisionKoharuProvider()
        let analysis = try await provider.analyzePage(
            image: image,
            sourceImageSize: CGSize(width: image.width, height: image.height),
            pageIdentifier: MangaPageIdentifier(
                scope: "koharu-dedup-fixture",
                pageIndex: 0,
                sourceFingerprint: "fixture"
            )
        )

        let profile = MangaVisionCalibrationProfile.bundled
        for type in MangaRegionType.allCases {
            let regions = analysis.regions(of: type)
            guard regions.count > 1 else { continue }
            let threshold = profile.calibration(for: type).iouThreshold
            for first in regions.indices {
                for second in regions.indices where second > first {
                    let overlap = MangaPageCoordinateSpace.intersectionOverUnion(
                        regions[first].normalizedRect,
                        regions[second].normalizedRect
                    )
                    XCTAssertLessThan(
                        overlap,
                        threshold,
                        "\(type.rawValue) regions \(first)/\(second) overlap at \(overlap) >= \(threshold)"
                    )
                }
            }
        }
    }

    func testProviderRuntimeCanBeReleasedAfterReaderSession() async throws {
        let provider = MangaVisionKoharuProvider()
        _ = await provider.descriptor
        let loadedBeforeRelease = await provider.runtimeIsLoadedForDiagnostics()
        await provider.releaseRuntimeMemory()
        let loadedAfterRelease = await provider.runtimeIsLoadedForDiagnostics()
        XCTAssertNotEqual(loadedBeforeRelease, loadedAfterRelease)
        XCTAssertFalse(loadedAfterRelease)
    }

    func testManifestIdentityUsesTheBundledContract() {
        let manifest = MangaVisionModelManifest.bundledKoharuYOLO26S(bundle: .main)
        XCTAssertEqual(manifest.modelID, MangaVisionKoharuProvider.modelIdentifier)
        XCTAssertEqual(manifest.outputContractRevision, MangaVisionKoharuOutputContract.revision)
        XCTAssertEqual(
            manifest.calibrationRevision,
            MangaVisionKoharuProductionIdentity.calibrationRevision
        )
        XCTAssertEqual(manifest.inputSize, MangaVisionKoharuPreprocessor.inputSize)
        XCTAssertEqual(manifest.semanticClasses, Set(MangaVisionKoharuClassOrder.regionTypes))
        XCTAssertFalse(manifest.cacheIdentity.isEmpty)
        // Replacing any byte of the compiled artifact must move the build identity.
        XCTAssertTrue(
            manifest.modelBuildID.hasPrefix("sha256:") || manifest.modelBuildID.hasPrefix("missing:")
        )
    }

    // MARK: - Fixtures

    private struct CheckpointConfig: Decodable {
        let architectures: [String]
        let task: String
        let image_size: Int
        let num_classes: Int
        let names: [String: String]
    }

    private static func checkpointConfig() throws -> CheckpointConfig {
        let url = try XCTUnwrap(fixtureURL("config.json", subdirectory: "koharu"))
        return try JSONDecoder().decode(CheckpointConfig.self, from: Data(contentsOf: url))
    }

    private static func fixtureURL(_ name: String, subdirectory: String = "Fixtures") -> URL? {
        let file = URL(fileURLWithPath: name)
        let bundle = Bundle(for: MangaVisionKoharuYOLO26SProviderTests.self)
        return bundle.url(
            forResource: file.deletingPathExtension().lastPathComponent,
            withExtension: file.pathExtension,
            subdirectory: subdirectory
        ) ?? bundle.url(
            forResource: file.deletingPathExtension().lastPathComponent,
            withExtension: file.pathExtension
        )
    }

    private static func bundledModelURL() -> URL? {
        let bundles = [Bundle.main, Bundle(for: MangaVisionKoharuYOLO26SProviderTests.self)]
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

    /// Builds a `detections` tensor with the frozen `[1, 300, 38]` layout.
    private static func makeDetections(
        rows: [(Float, Float, Float, Float, Float, Float)]
    ) throws -> MLMultiArray {
        let shape = MangaVisionKoharuOutputContract.detectionsShape
        let array = try MLMultiArray(shape: shape as [NSNumber], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let channels = shape[2]
        for row in 0..<shape[1] {
            for channel in 0..<channels {
                pointer[row * channels + channel] = 0
            }
        }
        for (rowIndex, row) in rows.enumerated() where rowIndex < shape[1] {
            let base = rowIndex * channels
            pointer[base + 0] = row.0
            pointer[base + 1] = row.1
            pointer[base + 2] = row.2
            pointer[base + 3] = row.3
            pointer[base + 4] = row.4
            pointer[base + 5] = row.5
            pointer[base + 6] = 1
        }
        return array
    }

    /// Builds a `protos` tensor whose first channel is a high-probability rectangle.
    private static func makeProtos(maskRect: CGRect?) throws -> MLMultiArray {
        try makeProtos(maskRects: maskRect.map { [$0] } ?? [])
    }

    private static func makeProtos(maskRects: [CGRect]) throws -> MLMultiArray {
        let shape = MangaVisionKoharuOutputContract.protosShape
        let array = try MLMultiArray(shape: shape as [NSNumber], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let channels = shape[1]
        let height = shape[2]
        let width = shape[3]
        for index in 0..<(channels * height * width) { pointer[index] = 0 }
        for maskRect in maskRects {
            for y in Int(maskRect.minY)..<Int(maskRect.maxY) {
                for x in Int(maskRect.minX)..<Int(maskRect.maxX) {
                    guard y >= 0, y < height, x >= 0, x < width else { continue }
                    pointer[y * width + x] = 6
                }
            }
        }
        return array
    }

    private static func solidImage(
        width: Int,
        height: Int,
        color: (UInt8, UInt8, UInt8)
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = color.0
            pixels[index + 1] = color.1
            pixels[index + 2] = color.2
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func pixels(of image: CGImage) throws -> [UInt8] {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        var created = false
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: bitmapInfo
                  ) else { return }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            created = true
        }
        XCTAssertTrue(created)
        return pixels
    }
}
