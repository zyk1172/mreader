import CoreGraphics
import CoreML
import Foundation
import XCTest
@testable import mreader

@MainActor
final class MangaLayout4V1AdapterTests: XCTestCase {
    func testFrozenFourClassMappingDoesNotReuseLegacyFaceBodyIndices() {
        XCTAssertEqual(
            MangaLayout4V1Class.allCases.map(\.rawValue),
            [0, 1, 2, 3]
        )
        XCTAssertEqual(
            MangaLayout4V1Class.allCases.map(\.semanticName),
            ["frame", "text", "balloon", "onomatopoeia"]
        )
        XCTAssertEqual(
            MangaLayout4V1Class.allCases.map(\.regionType),
            [.panel, .text, .balloon, .onomatopoeia]
        )
    }

    func testThirteenOutputContractIsNamedAndShapeFrozen() {
        XCTAssertEqual(MangaLayout4V1OutputContract.inputFeatureName, "image")
        XCTAssertEqual(MangaLayout4V1OutputContract.inputShape, [1, 3, 640, 640])
        XCTAssertEqual(MangaLayout4V1OutputContract.classCount, 4)
        XCTAssertEqual(MangaLayout4V1OutputContract.prototypeCount, 8)
        XCTAssertEqual(MangaLayout4V1OutputContract.specs.count, 13)
        XCTAssertEqual(
            MangaLayout4V1OutputContract.specs.map(\.name),
            [
                "p2_cls", "p2_bbox", "p2_mask_coeff",
                "p3_cls", "p3_bbox", "p3_mask_coeff",
                "p4_cls", "p4_bbox", "p4_mask_coeff",
                "p5_cls", "p5_bbox", "p5_mask_coeff",
                "mask_prototypes"
            ]
        )
        XCTAssertEqual(
            MangaLayout4V1OutputContract.spec(named: "p2_cls"),
            MangaLayout4V1OutputSpec(
                name: "p2_cls",
                level: "p2",
                role: "classification",
                channels: 4,
                height: 160,
                width: 160,
                stride: 4
            )
        )
        XCTAssertEqual(
            MangaLayout4V1OutputContract.spec(named: "mask_prototypes"),
            MangaLayout4V1OutputSpec(
                name: "mask_prototypes",
                level: "mask",
                role: "prototypes",
                channels: 8,
                height: 320,
                width: 320,
                stride: 2
            )
        )
    }

    func testFrozenTrainingPostprocessThresholdsMatchReferenceDecoder() {
        let config = MangaLayout4V1Configuration()
        for layoutClass in MangaLayout4V1Class.allCases {
            XCTAssertEqual(config.scoreThreshold(for: layoutClass), 0.05)
        }
        XCTAssertEqual(config.frameNMSThreshold, 0.50)
        XCTAssertEqual(config.textNMSThreshold, 0.50)
        XCTAssertEqual(config.balloonNMSThreshold, 0.45)
        XCTAssertEqual(config.onomatopoeiaNMSThreshold, 0.45)
    }

    func testGuidedPanelAcceptsQualityFocalFrameScoresKeptByLayout4() {
        let panels = [
            DetectedPanel(
                rect: CGRect(x: 0.05, y: 0.05, width: 0.42, height: 0.40),
                confidence: 0.09,
                source: .coreML
            ),
            DetectedPanel(
                rect: CGRect(x: 0.53, y: 0.05, width: 0.42, height: 0.40),
                confidence: 0.08,
                source: .coreML
            )
        ]
        let processed = PanelPostProcessor.process(panels)
        XCTAssertEqual(processed.count, 2)
        XCTAssertTrue(PanelLayoutQuality.isUsable(processed))
    }

    func testSigmoidFeatureGridAndSoftplusMatchReferenceMath() {
        XCTAssertEqual(MangaLayout4V1Decoder.sigmoid(0), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            MangaLayout4V1Decoder.sigmoid(Float(log(9.0))),
            0.9,
            accuracy: 0.000_001
        )
        let center = MangaLayout4V1Decoder.featureCenter(x: 3, y: 5, stride: 8)
        XCTAssertEqual(center.x, 28, accuracy: 0.000_001)
        XCTAssertEqual(center.y, 44, accuracy: 0.000_001)

        let raw = Float(log(exp(5.0) - 1))
        XCTAssertEqual(MangaLayout4V1Decoder.softplus(raw), 5, accuracy: 0.000_01)
    }

    func testLetterboxUsesPythonRoundToEvenAndRestoresOriginalCoordinates() throws {
        let tie = try MangaLayout4V1Letterbox.make(sourceWidth: 101, sourceHeight: 256)
        XCTAssertEqual(tie.resizedWidth, 252)
        XCTAssertEqual(tie.resizedHeight, 640)
        XCTAssertEqual(tie.padLeft, 194)
        XCTAssertEqual(tie.padRight, 194)
        XCTAssertEqual(tie.padTop, 0)
        XCTAssertEqual(tie.padBottom, 0)

        let letterbox = try MangaLayout4V1Letterbox.make(sourceWidth: 1000, sourceHeight: 1500)
        let sourceRect = CGRect(x: 0.17, y: 0.23, width: 0.41, height: 0.32)
        let modelRect = letterbox.modelRect(fromSourceNormalizedRect: sourceRect)
        let restored = letterbox.sourceNormalizedRect(fromModelRect: modelRect)
        XCTAssertEqual(restored.minX, sourceRect.minX, accuracy: 0.000_01)
        XCTAssertEqual(restored.minY, sourceRect.minY, accuracy: 0.000_01)
        XCTAssertEqual(restored.width, sourceRect.width, accuracy: 0.000_01)
        XCTAssertEqual(restored.height, sourceRect.height, accuracy: 0.000_01)
    }

    func testPreprocessorEmitsRGBZeroToOneAndWhitePadding() throws {
        let image = try makeSolidImage(width: 1, height: 2, rgba: [255, 0, 0, 255])
        let prepared = try MangaLayout4V1Preprocessor.makeInput(from: image)
        XCTAssertEqual(prepared.letterbox.resizedWidth, 320)
        XCTAssertEqual(prepared.letterbox.resizedHeight, 640)
        XCTAssertEqual(prepared.letterbox.padLeft, 160)
        XCTAssertEqual(prepared.letterbox.padRight, 160)

        XCTAssertEqual(value(prepared.array, channel: 0, y: 320, x: 0), 1, accuracy: 0.000_001)
        XCTAssertEqual(value(prepared.array, channel: 1, y: 320, x: 0), 1, accuracy: 0.000_001)
        XCTAssertEqual(value(prepared.array, channel: 2, y: 320, x: 0), 1, accuracy: 0.000_001)

        XCTAssertEqual(value(prepared.array, channel: 0, y: 320, x: 200), 1, accuracy: 0.000_001)
        XCTAssertEqual(value(prepared.array, channel: 1, y: 320, x: 200), 0, accuracy: 0.000_001)
        XCTAssertEqual(value(prepared.array, channel: 2, y: 320, x: 200), 0, accuracy: 0.000_001)
    }

    func testDecoderAppliesIndependentSigmoidPerClassAndSameClassNMSOnly() throws {
        var outputs = try makeRawOutputs()
        let p2Cls = try XCTUnwrap(outputs["p2_cls"])
        let p2BBox = try XCTUnwrap(outputs["p2_bbox"])
        let bboxRaw = Float(log(exp(5.0) - 1.0))

        for x in [10, 11] {
            set(p2Cls, channel: MangaLayout4V1Class.frame.rawValue, y: 10, x: x, value: logit(0.90))
            for channel in 0..<4 {
                set(p2BBox, channel: channel, y: 10, x: x, value: bboxRaw)
            }
        }
        // Same spatial location and almost identical box, different class.
        set(p2Cls, channel: MangaLayout4V1Class.text.rawValue, y: 10, x: 10, value: logit(0.80))

        let letterbox = try MangaLayout4V1Letterbox.make(sourceWidth: 640, sourceHeight: 640)
        let decoded = try MangaLayout4V1Decoder.decode(
            rawOutputs: outputs,
            letterbox: letterbox
        )

        XCTAssertEqual(decoded.detections.filter { $0.layoutClass == .frame }.count, 1)
        XCTAssertEqual(decoded.detections.filter { $0.layoutClass == .text }.count, 1)
        XCTAssertEqual(decoded.detections.filter { $0.layoutClass == .balloon }.count, 0)
        XCTAssertEqual(decoded.diagnostics.postThresholdCounts[.frame], 2)
        XCTAssertEqual(decoded.diagnostics.postThresholdCounts[.text], 1)
        XCTAssertEqual(decoded.diagnostics.postNMSCounts[.frame], 1)
        XCTAssertEqual(decoded.diagnostics.postNMSCounts[.text], 1)

        let frame = try XCTUnwrap(decoded.detections.first { $0.layoutClass == .frame })
        XCTAssertEqual(frame.modelRect.minX, 22, accuracy: 0.001)
        XCTAssertEqual(frame.modelRect.minY, 22, accuracy: 0.001)
        XCTAssertEqual(frame.modelRect.width, 40, accuracy: 0.002)
        XCTAssertEqual(frame.modelRect.height, 40, accuracy: 0.002)
    }

    func testDecoderKeepsQualityFocalFrameAboveFrozenTrainingThreshold() throws {
        var outputs = try makeRawOutputs()
        let p4Cls = try XCTUnwrap(outputs["p4_cls"])
        let p4BBox = try XCTUnwrap(outputs["p4_bbox"])
        set(
            p4Cls,
            channel: MangaLayout4V1Class.frame.rawValue,
            y: 8,
            x: 8,
            value: logit(0.06)
        )
        let bboxRaw = Float(log(exp(3.0) - 1.0))
        for channel in 0..<4 {
            set(p4BBox, channel: channel, y: 8, x: 8, value: bboxRaw)
        }

        let decoded = try MangaLayout4V1Decoder.decode(
            rawOutputs: outputs,
            letterbox: MangaLayout4V1Letterbox.make(sourceWidth: 640, sourceHeight: 640)
        )

        let frame = try XCTUnwrap(decoded.detections.first { $0.layoutClass == .frame })
        XCTAssertEqual(frame.confidence, 0.06, accuracy: 0.000_01)
        XCTAssertEqual(decoded.diagnostics.postThresholdCounts[.frame], 1)
    }

    func testBalloonMaskCombinationCropAndMultipleComponents() throws {
        let prototypes = try MLMultiArray(
            shape: [1, 8, 320, 320].map(NSNumber.init),
            dataType: .float32
        )
        fill(prototypes, with: -10)
        // Only channel 0 participates. Create two disconnected positive islands.
        for y in 40..<50 {
            for x in 50..<60 {
                set(prototypes, channel: 0, y: y, x: x, value: 10)
            }
        }
        for y in 100..<108 {
            for x in 120..<128 {
                set(prototypes, channel: 0, y: y, x: x, value: 10)
            }
        }
        // Other prototype channels must be neutral, not -10, because coeff=0 for them.
        for channel in 1..<8 {
            for y in 0..<320 {
                for x in 0..<320 {
                    set(prototypes, channel: channel, y: y, x: x, value: 0)
                }
            }
        }

        let detection = MangaLayout4V1Detection(
            layoutClass: .balloon,
            confidence: 0.9,
            modelRect: CGRect(x: 0, y: 0, width: 640, height: 640),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            pyramidLevel: "p2",
            maskCoefficients: [10, 0, 0, 0, 0, 0, 0, 0]
        )
        let letterbox = try MangaLayout4V1Letterbox.make(sourceWidth: 640, sourceHeight: 640)
        let instances = try MangaLayout4V1MaskDecoder.decodeBalloonInstances(
            detections: [detection],
            rawOutputs: ["mask_prototypes": prototypes],
            letterbox: letterbox
        )
        let instance = try XCTUnwrap(instances.first)
        XCTAssertEqual(instance.mask.foregroundPixelCount, 164)
        XCTAssertEqual(instance.componentSummaries.count, 2)
        XCTAssertEqual(instance.contours.count, 2)
        XCTAssertEqual(instance.componentSummaries.map(\.pixelCount), [100, 64])

        var expectedPixels = [UInt8](repeating: 0, count: 320 * 320)
        for y in 40..<50 {
            for x in 50..<60 { expectedPixels[y * 320 + x] = 1 }
        }
        for y in 100..<108 {
            for x in 120..<128 { expectedPixels[y * 320 + x] = 1 }
        }
        let expected = MangaLayout4V1BinaryMask(
            width: 320,
            height: 320,
            pixels: expectedPixels
        )
        XCTAssertEqual(instance.mask.intersectionOverUnion(with: expected), 1, accuracy: 0.000_001)
    }

    func testDomainPreservesSFXAndSecondaryBalloonContoursWithoutFakeFaceBody() {
        let primary = MangaVisionContour(points: [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.2, y: 0.2)
        ])
        let secondary = MangaVisionContour(points: [
            CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.4, y: 0.4)
        ])
        let balloon = MangaVisionRegion(
            type: .balloon,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            confidence: 0.8,
            contour: primary,
            secondaryContours: [secondary]
        )
        let sfx = MangaVisionRegion(
            type: .onomatopoeia,
            normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1),
            confidence: 0.7
        )
        let analysis = MangaPageAnalysis(
            pageIdentifier: MangaPageIdentifier(scope: "layout4", pageIndex: 0, sourceFingerprint: "fixture"),
            imageSize: CGSize(width: 640, height: 640),
            panels: [],
            texts: [],
            balloons: [balloon],
            onomatopoeias: [sfx],
            modelIdentifier: MangaLayout4V1Provider.modelIdentifier,
            modelVersion: 1
        )
        XCTAssertEqual(analysis.balloons.first?.contours.count, 2)
        XCTAssertEqual(analysis.onomatopoeias.map(\.id), [sfx.id])
        XCTAssertEqual(MangaRegionType.allCases, [.panel, .text, .balloon, .onomatopoeia])
    }

    func testMangaLayout4CapabilitiesAreExplicit() async {
        let descriptor = await MangaLayout4V1Provider.shared.descriptor
        let capabilities = descriptor.capabilities
        XCTAssertTrue(capabilities.supportsFrame)
        XCTAssertTrue(capabilities.supportsText)
        XCTAssertTrue(capabilities.supportsBalloon)
        XCTAssertTrue(capabilities.supportsOnomatopoeia)
        XCTAssertTrue(capabilities.supportsBalloonMask)
    }

    func testIntegrationBranchServiceIsMangaLayout4Only() async {
        let manifest = await MangaVisionService.shared.modelManifestForDiagnostics()
        XCTAssertEqual(manifest.modelID, MangaLayout4V1Provider.modelIdentifier)
        XCTAssertEqual(
            manifest.semanticClasses,
            Set([.panel, .text, .balloon, .onomatopoeia])
        )
    }

    func testBundledFormalModelMatchesThirteenOutputContract() throws {
        let modelURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: MangaLayout4V1Provider.modelResourceName,
                withExtension: "mlmodelc"
            ),
            "MangaLayout4V1.mlmodelc must be compiled into every app/test build"
        )
        let model = try MLModel(contentsOf: modelURL)
        XCTAssertEqual(
            MangaLayout4V1OutputContract.validate(modelDescription: model.modelDescription),
            []
        )
    }

    func testBundledFormalModelProducesUsableNavigationFramesOnRealMangaPage() async throws {
        let bundles = [Bundle(for: Self.self), Bundle.main] + Bundle.allBundles
        let fixtureURL = try XCTUnwrap(
            bundles.lazy.compactMap { bundle in
                bundle.url(
                    forResource: "manga_page_publicdomainq",
                    withExtension: "png",
                    subdirectory: "Fixtures"
                ) ?? bundle.url(
                    forResource: "manga_page_publicdomainq",
                    withExtension: "png"
                )
            }.first,
            "real manga fixture must be bundled"
        )
        let image = try XCTUnwrap(UIImage(contentsOfFile: fixtureURL.path))
        let cgImage = try XCTUnwrap(image.cgImage)
        let identifier = MangaPageIdentifier(
            scope: "layout4-real-fixture",
            pageIndex: 0,
            sourceFingerprint: "manga-page-publicdomainq"
        )

        let analysis = try await MangaLayout4V1Provider.shared.analyzePage(
            image: cgImage,
            sourceImageSize: CGSize(width: cgImage.width, height: cgImage.height),
            pageIdentifier: identifier
        )

        XCTAssertFalse(analysis.panels.isEmpty, "real Layout4 inference returned zero frame detections")
        XCTAssertTrue(analysis.panels.allSatisfy { region in
            let rect = region.normalizedRect
            return region.type == .panel
                && region.confidence >= MangaLayout4V1Configuration().frameScoreThreshold
                && rect.minX >= 0 && rect.minY >= 0
                && rect.maxX <= 1 && rect.maxY <= 1
                && rect.width > 0 && rect.height > 0
        })

        let navigation = PanelPostProcessor.process(
            analysis.panels.map {
                DetectedPanel(
                    rect: $0.normalizedRect,
                    confidence: $0.confidence,
                    source: .coreML,
                    contour: $0.contour?.cgPoints
                )
            }
        )
        XCTAssertFalse(navigation.isEmpty, "real Layout4 frames were all removed before Guided Panel")
        XCTAssertLessThanOrEqual(navigation.count, 20)
    }

    private func makeRawOutputs() throws -> [String: MLMultiArray] {
        var outputs: [String: MLMultiArray] = [:]
        for spec in MangaLayout4V1OutputContract.specs {
            let array = try MLMultiArray(
                shape: [1, spec.channels, spec.height, spec.width].map(NSNumber.init),
                dataType: .float32
            )
            fill(array, with: spec.role == "classification" ? -100 : 0)
            outputs[spec.name] = array
        }
        return outputs
    }

    private func fill(_ array: MLMultiArray, with value: Float) {
        let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
        for index in 0..<array.count {
            pointer[index] = value
        }
    }

    private func set(
        _ array: MLMultiArray,
        channel: Int,
        y: Int,
        x: Int,
        value: Float
    ) {
        let strides = array.strides.map(\.intValue)
        let offset = channel * strides[1] + y * strides[2] + x * strides[3]
        array.dataPointer
            .assumingMemoryBound(to: Float32.self)
            .advanced(by: offset)
            .pointee = value
    }

    private func value(
        _ array: MLMultiArray,
        channel: Int,
        y: Int,
        x: Int
    ) -> Float {
        let strides = array.strides.map(\.intValue)
        let offset = channel * strides[1] + y * strides[2] + x * strides[3]
        return array.dataPointer
            .assumingMemoryBound(to: Float32.self)
            .advanced(by: offset)
            .pointee
    }

    private func logit(_ probability: Float) -> Float {
        log(probability / (1 - probability))
    }

    private func makeSolidImage(
        width: Int,
        height: Int,
        rgba: [UInt8]
    ) throws -> CGImage {
        XCTAssertEqual(rgba.count, 4)
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(contentsOf: rgba)
        }
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(pixels) as CFData)
        )
        return try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }
}
