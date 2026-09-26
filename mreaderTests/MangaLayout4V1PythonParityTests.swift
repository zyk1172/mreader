import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import mreader

@MainActor
final class MangaLayout4V1PythonParityTests: XCTestCase {
    func testPythonReferenceSyntheticPostprocessParity() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            fixture.revision,
            "manga-layout4-v1-python-swift-synthetic-parity-v1"
        )
        XCTAssertEqual(fixture.cases.count, 8)

        for testCase in fixture.cases {
            let outputs = try rawOutputs(for: testCase)
            let letterbox = try MangaLayout4V1Letterbox.make(
                sourceWidth: testCase.sourceWidth,
                sourceHeight: testCase.sourceHeight
            )
            assertLetterbox(letterbox, equals: testCase.letterbox, caseName: testCase.name)

            let decoded = try MangaLayout4V1Decoder.decode(
                rawOutputs: outputs,
                letterbox: letterbox
            )
            assertDetections(
                decoded.detections,
                equal: testCase.expected.detections,
                caseName: testCase.name
            )
            assertDiagnostics(
                decoded.diagnostics,
                equal: testCase.expected.diagnostics,
                caseName: testCase.name
            )

            let balloons = try MangaLayout4V1MaskDecoder.decodeBalloonInstances(
                detections: decoded.detections,
                rawOutputs: outputs,
                letterbox: letterbox
            )
            assertBalloons(
                balloons,
                equal: testCase.expected.balloons,
                caseName: testCase.name
            )
        }
    }

    private func rawOutputs(
        for testCase: ParityCase
    ) throws -> [String: MLMultiArray] {
        var outputs: [String: MLMultiArray] = [:]
        for spec in MangaLayout4V1OutputContract.specs {
            let array = try MLMultiArray(
                shape: [1, spec.channels, spec.height, spec.width].map(NSNumber.init),
                dataType: .float32
            )
            fill(
                array,
                with: spec.role == "classification" ? -100 : 0
            )
            outputs[spec.name] = array
        }

        for candidate in testCase.candidates {
            guard let layoutClass = layoutClass(named: candidate.className),
                  let classificationSpec = MangaLayout4V1OutputContract.spec(
                    level: candidate.level,
                    role: "classification"
                  ),
                  let bboxSpec = MangaLayout4V1OutputContract.spec(
                    level: candidate.level,
                    role: "bbox"
                  ),
                  let coefficientSpec = MangaLayout4V1OutputContract.spec(
                    level: candidate.level,
                    role: "mask_coeff"
                  ),
                  let classification = outputs[classificationSpec.name],
                  let bbox = outputs[bboxSpec.name],
                  let coefficients = outputs[coefficientSpec.name] else {
                XCTFail("Unknown parity candidate contract: \(testCase.name)")
                continue
            }
            set(
                classification,
                channel: layoutClass.rawValue,
                y: candidate.y,
                x: candidate.x,
                value: logit(Float(candidate.score))
            )
            for channel in 0..<4 {
                let distance = Float(candidate.distances[channel])
                let raw = inverseSoftplus(
                    distance / Float(bboxSpec.stride)
                )
                set(
                    bbox,
                    channel: channel,
                    y: candidate.y,
                    x: candidate.x,
                    value: raw
                )
            }
            for (channel, raw) in (candidate.coefficients ?? []).enumerated() {
                set(
                    coefficients,
                    channel: channel,
                    y: candidate.y,
                    x: candidate.x,
                    value: Float(raw)
                )
            }
        }

        if !testCase.expected.balloons.isEmpty,
           let prototypes = outputs["mask_prototypes"] {
            for (channel, value) in testCase.prototypeDefaults.enumerated() {
                fillChannel(
                    prototypes,
                    channel: channel,
                    with: Float(value)
                )
            }
            for rectangle in testCase.prototypeRectangles {
                for y in rectangle.y1..<rectangle.y2 {
                    for x in rectangle.x1..<rectangle.x2 {
                        set(
                            prototypes,
                            channel: rectangle.channel,
                            y: y,
                            x: x,
                            value: Float(rectangle.value)
                        )
                    }
                }
            }
        }
        return outputs
    }

    private func assertLetterbox(
        _ actual: MangaLayout4V1Letterbox,
        equals expected: ParityLetterbox,
        caseName: String
    ) {
        XCTAssertEqual(actual.originalWidth, expected.originalWidth, caseName)
        XCTAssertEqual(actual.originalHeight, expected.originalHeight, caseName)
        XCTAssertEqual(actual.scale, expected.scale, accuracy: 0.000_000_1, caseName)
        XCTAssertEqual(actual.resizedWidth, expected.resizedWidth, caseName)
        XCTAssertEqual(actual.resizedHeight, expected.resizedHeight, caseName)
        XCTAssertEqual(actual.padLeft, expected.padLeft, caseName)
        XCTAssertEqual(actual.padTop, expected.padTop, caseName)
        XCTAssertEqual(actual.padRight, expected.padRight, caseName)
        XCTAssertEqual(actual.padBottom, expected.padBottom, caseName)
    }

    private func assertDetections(
        _ actual: [MangaLayout4V1Detection],
        equal expected: [ParityExpectedDetection],
        caseName: String
    ) {
        XCTAssertEqual(actual.count, expected.count, caseName)
        guard actual.count == expected.count else { return }
        for (index, pair) in zip(actual, expected).enumerated() {
            let detected = pair.0
            let reference = pair.1
            XCTAssertEqual(
                detected.layoutClass.semanticName,
                reference.className,
                "\(caseName) detection \(index)"
            )
            XCTAssertEqual(
                detected.pyramidLevel,
                reference.level,
                "\(caseName) detection \(index)"
            )
            XCTAssertEqual(
                detected.confidence,
                Float(reference.score),
                accuracy: 0.000_01,
                "\(caseName) detection \(index)"
            )
            assertRect(
                detected.modelRect,
                equals: reference.modelBox,
                accuracy: 0.001,
                message: "\(caseName) model detection \(index)"
            )
            assertRect(
                detected.normalizedRect,
                equals: reference.normalizedBox,
                accuracy: 0.000_01,
                message: "\(caseName) normalized detection \(index)"
            )
        }
    }

    private func assertDiagnostics(
        _ actual: MangaLayout4V1DecodeDiagnostics,
        equal expected: ParityExpectedDiagnostics,
        caseName: String
    ) {
        XCTAssertEqual(
            actual.totalLocationClassCount,
            expected.totalLocationClassCount,
            caseName
        )
        XCTAssertEqual(
            actual.preThresholdTopKCount,
            expected.preThresholdTopKCount,
            caseName
        )
        for layoutClass in MangaLayout4V1Class.allCases {
            let name = layoutClass.semanticName
            XCTAssertEqual(
                actual.postThresholdCounts[layoutClass] ?? 0,
                expected.postThresholdCounts[name] ?? 0,
                "\(caseName) threshold \(name)"
            )
            XCTAssertEqual(
                actual.postNMSCounts[layoutClass] ?? 0,
                expected.postNmsCounts[name] ?? 0,
                "\(caseName) NMS \(name)"
            )
            XCTAssertEqual(
                actual.maximumScores[layoutClass] ?? 0,
                Float(expected.maximumScores[name] ?? 0),
                accuracy: 0.000_01,
                "\(caseName) max score \(name)"
            )
        }
    }

    private func assertBalloons(
        _ actual: [MangaLayout4V1BalloonInstance],
        equal expected: [ParityExpectedBalloon],
        caseName: String
    ) {
        XCTAssertEqual(actual.count, expected.count, caseName)
        guard actual.count == expected.count else { return }
        for (index, pair) in zip(actual, expected).enumerated() {
            let instance = pair.0
            let reference = pair.1
            XCTAssertEqual(
                instance.mask.foregroundPixelCount,
                reference.foregroundPixelCount,
                "\(caseName) balloon \(index) pixel count"
            )
            let digest = SHA256.hash(data: Data(instance.mask.pixels))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(
                digest,
                reference.maskSha256,
                "\(caseName) balloon \(index) pixel-perfect mask"
            )
            XCTAssertEqual(
                instance.componentSummaries.map(\.pixelCount),
                reference.componentPixelCounts,
                "\(caseName) balloon \(index) components"
            )
            XCTAssertEqual(
                instance.componentSummaries.count,
                reference.componentBounds.count,
                "\(caseName) balloon \(index) component bounds"
            )
            if instance.componentSummaries.count == reference.componentBounds.count {
                for componentIndex in instance.componentSummaries.indices {
                    assertRect(
                        instance.componentSummaries[componentIndex].prototypeBounds,
                        equals: reference.componentBounds[componentIndex].map(Double.init),
                        accuracy: 0.000_01,
                        message: "\(caseName) balloon \(index) component \(componentIndex)"
                    )
                }
            }

            XCTAssertEqual(
                instance.contours.count,
                reference.contours.count,
                "\(caseName) balloon \(index) contour count"
            )
            guard instance.contours.count == reference.contours.count else {
                continue
            }
            for contourIndex in instance.contours.indices {
                let actualPoints = instance.contours[contourIndex].cgPoints
                let expectedPoints = reference.contours[contourIndex]
                XCTAssertEqual(
                    actualPoints.count,
                    expectedPoints.count,
                    "\(caseName) balloon \(index) contour \(contourIndex)"
                )
                guard actualPoints.count == expectedPoints.count else { continue }
                for pointIndex in actualPoints.indices {
                    XCTAssertEqual(
                        actualPoints[pointIndex].x,
                        CGFloat(expectedPoints[pointIndex][0]),
                        accuracy: 0.000_001,
                        "\(caseName) contour x \(pointIndex)"
                    )
                    XCTAssertEqual(
                        actualPoints[pointIndex].y,
                        CGFloat(expectedPoints[pointIndex][1]),
                        accuracy: 0.000_001,
                        "\(caseName) contour y \(pointIndex)"
                    )
                }
            }
        }
    }

    private func assertRect(
        _ rect: CGRect,
        equals values: [Double],
        accuracy: CGFloat,
        message: String
    ) {
        XCTAssertEqual(values.count, 4, message)
        guard values.count == 4 else { return }
        XCTAssertEqual(rect.minX, CGFloat(values[0]), accuracy: accuracy, message)
        XCTAssertEqual(rect.minY, CGFloat(values[1]), accuracy: accuracy, message)
        XCTAssertEqual(rect.width, CGFloat(values[2]), accuracy: accuracy, message)
        XCTAssertEqual(rect.height, CGFloat(values[3]), accuracy: accuracy, message)
    }

    private func loadFixture() throws -> ParityFixture {
        let bundles = [Bundle(for: Self.self), Bundle.main]
            + Bundle.allBundles
            + Bundle.allFrameworks
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "manga_layout4_v1_reference_parity",
                withExtension: "json",
                subdirectory: "Fixtures"
            ) ?? bundle.url(
                forResource: "manga_layout4_v1_reference_parity",
                withExtension: "json"
            ) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(
                    ParityFixture.self,
                    from: Data(contentsOf: url)
                )
            }
        }
        throw XCTSkip(
            "Run scripts/generate_manga_layout4_v1_reference_fixture.py before local tests"
        )
    }

    private func layoutClass(named name: String) -> MangaLayout4V1Class? {
        MangaLayout4V1Class.allCases.first { $0.semanticName == name }
    }

    private func logit(_ probability: Float) -> Float {
        log(probability / (1 - probability))
    }

    private func inverseSoftplus(_ value: Float) -> Float {
        if value > 20 { return value }
        return log(expm1(value))
    }

    private func fill(_ array: MLMultiArray, with value: Float) {
        let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
        for index in 0..<array.count {
            pointer[index] = value
        }
    }

    private func fillChannel(
        _ array: MLMultiArray,
        channel: Int,
        with value: Float
    ) {
        let height = array.shape[2].intValue
        let width = array.shape[3].intValue
        for y in 0..<height {
            for x in 0..<width {
                set(array, channel: channel, y: y, x: x, value: value)
            }
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
}

private struct ParityFixture: Decodable {
    let revision: String
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let sourceWidth: Int
    let sourceHeight: Int
    let letterbox: ParityLetterbox
    let candidates: [ParityCandidate]
    let prototypeDefaults: [Double]
    let prototypeRectangles: [ParityPrototypeRectangle]
    let expected: ParityExpected
}

private struct ParityLetterbox: Decodable {
    let originalWidth: Int
    let originalHeight: Int
    let scale: CGFloat
    let resizedWidth: Int
    let resizedHeight: Int
    let padLeft: Int
    let padTop: Int
    let padRight: Int
    let padBottom: Int
}

private struct ParityCandidate: Decodable {
    let level: String
    let className: String
    let x: Int
    let y: Int
    let score: Double
    let distances: [Double]
    let coefficients: [Double]?

    private enum CodingKeys: String, CodingKey {
        case level, x, y, score, distances, coefficients
        case className = "class"
    }
}

private struct ParityPrototypeRectangle: Decodable {
    let channel: Int
    let value: Double
    let x1: Int
    let y1: Int
    let x2: Int
    let y2: Int
}

private struct ParityExpected: Decodable {
    let detections: [ParityExpectedDetection]
    let diagnostics: ParityExpectedDiagnostics
    let balloons: [ParityExpectedBalloon]
}

private struct ParityExpectedDetection: Decodable {
    let className: String
    let score: Double
    let level: String
    let modelBox: [Double]
    let normalizedBox: [Double]

    private enum CodingKeys: String, CodingKey {
        case score, level, modelBox, normalizedBox
        case className = "class"
    }
}

private struct ParityExpectedDiagnostics: Decodable {
    let totalLocationClassCount: Int
    let preThresholdTopKCount: Int
    let postThresholdCounts: [String: Int]
    let postNmsCounts: [String: Int]
    let maximumScores: [String: Double]
}

private struct ParityExpectedBalloon: Decodable {
    let foregroundPixelCount: Int
    let maskSha256: String
    let componentPixelCounts: [Int]
    let componentBounds: [[Int]]
    let contours: [[[Double]]]
}
