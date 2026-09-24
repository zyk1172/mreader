import CoreGraphics
import CoreML
import Foundation
import os

/// The frozen five-class order from `configs/manga109s_v2b5_calibration.yaml`.
/// `panel` is the app-side semantic name for the model's `frame` class.
nonisolated enum MangaVisionV2B5ClassOrder {
    static let labels = ["frame", "text", "face", "body", "balloon"]
    static let regionTypes: [MangaRegionType] = [.panel, .text, .face, .body, .balloon]
}

nonisolated struct MangaVisionV2B5OutputSpec: Sendable, Equatable {
    let semanticName: String
    let outputName: String
    let level: String
    let role: String
    let channels: Int
    let width: Int
    let height: Int
    let stride: Int
}

nonisolated enum MangaVisionV2B5OutputContract {
    static let revision = "manga-vision-v2b5-fcos-raw-output-v1"
    static let inputFeatureName = "input"
    static let inputShape = [1, 3, 640, 640]

    /// These names are the verified ML Program output names. They are mapped by
    /// this table and shape contract, never by sorting feature names or relying
    /// on Core ML enumeration order.
    static let specs: [MangaVisionV2B5OutputSpec] = [
        spec("p2_cls", "conv2d_77", "p2", "classification", 5, 160, 160, 4),
        spec("p2_bbox", "conv2d_78", "p2", "bbox", 4, 160, 160, 4),
        spec("p2_centerness", "conv2d_79", "p2", "centerness", 1, 160, 160, 4),
        spec("p3_cls", "conv2d_88", "p3", "classification", 5, 80, 80, 8),
        spec("p3_bbox", "conv2d_89", "p3", "bbox", 4, 80, 80, 8),
        spec("p3_centerness", "conv2d_90", "p3", "centerness", 1, 80, 80, 8),
        spec("p4_cls", "conv2d_99", "p4", "classification", 5, 40, 40, 16),
        spec("p4_bbox", "conv2d_100", "p4", "bbox", 4, 40, 40, 16),
        spec("p4_centerness", "conv2d_101", "p4", "centerness", 1, 40, 40, 16),
        spec("p5_cls", "conv2d_110", "p5", "classification", 5, 20, 20, 32),
        spec("p5_bbox", "conv2d_111", "p5", "bbox", 4, 20, 20, 32),
        spec("p5_centerness", "conv2d_112", "p5", "centerness", 1, 20, 20, 32)
    ]

    private static func spec(
        _ semanticName: String,
        _ outputName: String,
        _ level: String,
        _ role: String,
        _ channels: Int,
        _ width: Int,
        _ height: Int,
        _ stride: Int
    ) -> MangaVisionV2B5OutputSpec {
        MangaVisionV2B5OutputSpec(
            semanticName: semanticName,
            outputName: outputName,
            level: level,
            role: role,
            channels: channels,
            width: width,
            height: height,
            stride: stride
        )
    }

    static var outputNames: Set<String> { Set(specs.map(\.outputName)) }

    static func spec(named semanticName: String) -> MangaVisionV2B5OutputSpec? {
        specs.first { $0.semanticName == semanticName }
    }

    static func validate(modelDescription: MLModelDescription) -> [String] {
        var violations: [String] = []
        guard let input = modelDescription.inputDescriptionsByName[inputFeatureName] else {
            return ["missing-input:\(inputFeatureName)"]
        }
        guard input.type == .multiArray,
              let inputShape = input.multiArrayConstraint?.shape.map(\.intValue) else {
            violations.append("input-is-not-multiarray")
            return violations
        }
        if inputShape != inputShapeContract {
            violations.append("input-shape:\(inputShape)")
        }

        let outputs = modelDescription.outputDescriptionsByName
        if Set(outputs.keys) != outputNames {
            let missing = outputNames.subtracting(outputs.keys).sorted()
            let extra = Set(outputs.keys).subtracting(outputNames).sorted()
            if !missing.isEmpty { violations.append("missing-outputs:\(missing.joined(separator: ","))") }
            if !extra.isEmpty { violations.append("unexpected-outputs:\(extra.joined(separator: ","))") }
        }
        for outputSpec in specs {
            guard let description = outputs[outputSpec.outputName] else { continue }
            guard description.type == .multiArray,
                  let shape = description.multiArrayConstraint?.shape.map(\.intValue) else {
                violations.append("output-not-multiarray:\(outputSpec.outputName)")
                continue
            }
            let expected = [1, outputSpec.channels, outputSpec.height, outputSpec.width]
            if shape != expected {
                violations.append("output-shape:\(outputSpec.outputName)=\(shape),expected=\(expected)")
            }
        }
        return violations
    }

    static let inputShapeContract = inputShape

    static func rawOutputs(from provider: MLFeatureProvider) throws -> [String: MLMultiArray] {
        var result: [String: MLMultiArray] = [:]
        for outputSpec in specs {
            guard let array = provider.featureValue(for: outputSpec.outputName)?.multiArrayValue else {
                throw MangaVisionV2B5Error.missingOutput(outputSpec.outputName)
            }
            let actual = array.shape.map(\.intValue)
            let expected = [1, outputSpec.channels, outputSpec.height, outputSpec.width]
            guard actual == expected else {
                throw MangaVisionV2B5Error.outputShape(
                    name: outputSpec.outputName,
                    actual: actual,
                    expected: expected
                )
            }
            result[outputSpec.outputName] = array
        }
        return result
    }
}

nonisolated enum MangaVisionV2B5Error: Error, Sendable, Equatable {
    case modelUnavailable
    case invalidContract([String])
    case missingOutput(String)
    case outputShape(name: String, actual: [Int], expected: [Int])
    case invalidInput(String)
    case unsupportedOutputDataType(name: String, actual: String)
}

/// Exact letterbox metadata retained with each model input. The model sees only
/// the square tensor; the decoder uses this value to restore page coordinates.
nonisolated struct MangaVisionV2B5Letterbox: Sendable, Equatable {
    let scale: CGFloat
    let paddingXY: CGPoint
    let originalSize: CGSize
    let inputSize: CGSize

    static func make(sourceSize: CGSize, inputSize: CGSize = CGSize(width: 640, height: 640)) -> Self {
        let sourceWidth = max(sourceSize.width, 1)
        let sourceHeight = max(sourceSize.height, 1)
        let scale = min(inputSize.width / sourceWidth, inputSize.height / sourceHeight)
        let resizedWidth = max((sourceWidth * scale).rounded(), 1)
        let resizedHeight = max((sourceHeight * scale).rounded(), 1)
        return Self(
            scale: scale,
            paddingXY: CGPoint(
                x: ((inputSize.width - resizedWidth) / 2).rounded(.down),
                y: ((inputSize.height - resizedHeight) / 2).rounded(.down)
            ),
            originalSize: CGSize(width: sourceWidth, height: sourceHeight),
            inputSize: inputSize
        )
    }

    func sourceNormalizedRect(fromInputRect rect: CGRect) -> CGRect {
        let scaledWidth = max(originalSize.width * scale, 1)
        let scaledHeight = max(originalSize.height * scale, 1)
        return MangaPageCoordinateSpace.clampedNormalizedRect(CGRect(
            x: (rect.minX - paddingXY.x) / scaledWidth,
            y: (rect.minY - paddingXY.y) / scaledHeight,
            width: rect.width / scaledWidth,
            height: rect.height / scaledHeight
        ))
    }
}

nonisolated struct MangaVisionV2B5PreparedInput {
    let array: MLMultiArray
    let letterbox: MangaVisionV2B5Letterbox
}

nonisolated enum MangaVisionV2B5Preprocessor {
    static let inputSize = CGSize(width: 640, height: 640)

    static func makeInput(from image: CGImage) throws -> MangaVisionV2B5PreparedInput {
        guard image.width > 0, image.height > 0 else {
            throw MangaVisionV2B5Error.invalidInput("empty CGImage")
        }
        let sourceSize = CGSize(width: image.width, height: image.height)
        let letterbox = MangaVisionV2B5Letterbox.make(sourceSize: sourceSize, inputSize: inputSize)
        let resizedWidth = max(Int((sourceSize.width * letterbox.scale).rounded()), 1)
        let resizedHeight = max(Int((sourceSize.height * letterbox.scale).rounded()), 1)
        let width = Int(inputSize.width)
        let height = Int(inputSize.height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        var sourcePixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        var sourceContextCreated = false
        sourcePixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let sourceContext = CGContext(
                      data: baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: bitmapInfo
                  ) else { return }
            sourceContext.interpolationQuality = .none
            sourceContext.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            sourceContextCreated = true
        }
        guard sourceContextCreated else {
            throw MangaVisionV2B5Error.invalidInput("cannot allocate RGB source canvas")
        }

        // Build the letterbox in top-left row order. The training transform
        // uses Pillow's downsampling implementation, whose bilinear filter
        // widens with the scale factor and is applied as two fixed-point
        // separable passes. Reproduce that contract here instead of relying on
        // Core Graphics' platform-dependent interpolation kernel.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let resized = pillowBilinearResize(
            sourcePixels: sourcePixels,
            sourceWidth: image.width,
            sourceHeight: image.height,
            destinationWidth: resizedWidth,
            destinationHeight: resizedHeight
        )
        for y in 0..<resizedHeight {
            for x in 0..<resizedWidth {
                let sourceOffset = (y * resizedWidth + x) * 3
                let destinationOffset = ((Int(letterbox.paddingXY.y) + y) * width
                    + Int(letterbox.paddingXY.x) + x) * 4
                pixels[destinationOffset] = resized[sourceOffset]
                pixels[destinationOffset + 1] = resized[sourceOffset + 1]
                pixels[destinationOffset + 2] = resized[sourceOffset + 2]
                pixels[destinationOffset + 3] = 255
            }
        }

        let planeSize = width * height
        var values = [Float32](repeating: 0, count: planeSize * 3)
        for y in 0..<height {
            for x in 0..<width {
                let sourceOffset = (y * width + x) * 4
                let destinationOffset = y * width + x
                values[destinationOffset] = Float32(pixels[sourceOffset]) / 255
                values[planeSize + destinationOffset] = Float32(pixels[sourceOffset + 1]) / 255
                values[(planeSize * 2) + destinationOffset] = Float32(pixels[sourceOffset + 2]) / 255
            }
        }

        guard let array = try? MLMultiArray(
            shape: MangaVisionV2B5OutputContract.inputShape.map(NSNumber.init),
            dataType: .float32
        ) else {
            throw MangaVisionV2B5Error.invalidInput("cannot allocate NCHW input")
        }
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            array.dataPointer.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
        return MangaVisionV2B5PreparedInput(array: array, letterbox: letterbox)
    }

    private static func pillowBilinearResize(
        sourcePixels: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> [UInt8] {
        let precisionBits = 22
        let fixedScale = 1 << precisionBits

        func coefficients(sourceSize: Int, destinationSize: Int) -> [(start: Int, weights: [Int])] {
            let scale = Double(sourceSize) / Double(destinationSize)
            let filterScale = max(scale, 1.0)
            let support = filterScale
            let kernelSize = Int(ceil(support)) * 2 + 1
            return (0..<destinationSize).map { outputIndex in
                let center = (Double(outputIndex) + 0.5) * scale
                var start = Int(center - support + 0.5)
                start = max(start, 0)
                var end = Int(center + support + 0.5)
                end = min(end, sourceSize)
                let count = max(end - start, 0)
                var raw = [Double](repeating: 0, count: count)
                var sum = 0.0
                for index in 0..<count {
                    let distance = (Double(index + start) - center + 0.5) / filterScale
                    let absoluteDistance = abs(distance)
                    let weight = absoluteDistance < 1.0 ? 1.0 - absoluteDistance : 0.0
                    raw[index] = weight
                    sum += weight
                }
                var fixed = [Int](repeating: 0, count: kernelSize)
                if sum != 0 {
                    for index in 0..<count {
                        fixed[index] = Int(0.5 + raw[index] / sum * Double(fixedScale))
                    }
                }
                return (start, fixed)
            }
        }

        let horizontalCoefficients = coefficients(sourceSize: sourceWidth, destinationSize: destinationWidth)
        let verticalCoefficients = coefficients(sourceSize: sourceHeight, destinationSize: destinationHeight)
        var horizontal = [UInt8](repeating: 0, count: sourceHeight * destinationWidth * 3)
        for y in 0..<sourceHeight {
            for x in 0..<destinationWidth {
                let coefficient = horizontalCoefficients[x]
                for channel in 0..<3 {
                    var accumulator = 1 << (precisionBits - 1)
                    for index in coefficient.weights.indices {
                        let sourceX = coefficient.start + index
                        guard sourceX < sourceWidth else { continue }
                        accumulator += Int(sourcePixels[(y * sourceWidth + sourceX) * 4 + channel])
                            * coefficient.weights[index]
                    }
                    horizontal[(y * destinationWidth + x) * 3 + channel] = UInt8(max(min(accumulator >> precisionBits, 255), 0))
                }
            }
        }

        var output = [UInt8](repeating: 0, count: destinationHeight * destinationWidth * 3)
        for y in 0..<destinationHeight {
            let coefficient = verticalCoefficients[y]
            for x in 0..<destinationWidth {
                for channel in 0..<3 {
                    var accumulator = 1 << (precisionBits - 1)
                    for index in coefficient.weights.indices {
                        let sourceY = coefficient.start + index
                        guard sourceY < sourceHeight else { continue }
                        accumulator += Int(horizontal[(sourceY * destinationWidth + x) * 3 + channel])
                            * coefficient.weights[index]
                    }
                    output[(y * destinationWidth + x) * 3 + channel] = UInt8(max(min(accumulator >> precisionBits, 255), 0))
                }
            }
        }
        return output
    }
}

nonisolated struct MangaVisionV2B5Detection: Sendable, Equatable {
    let type: MangaRegionType
    let normalizedRect: CGRect
    let confidence: Float
    let pyramidLevel: String
}

/// A validated, stride-aware view over one Core ML output tensor.
///
/// `MLMultiArray` subscripting allocates an NSNumber index array for every
/// scalar read. V2B5 has millions of scalar reads per page, so the decoder
/// keeps the array alive and reads its validated Float32 storage directly.
/// The offset uses the runtime-provided strides; this deliberately does not
/// assume that Core ML returned a contiguous tensor.
nonisolated struct MangaVisionV2B5TensorReader {
    private let storage: MLMultiArray
    private let pointer: UnsafeRawPointer
    private let strides: [Int]

    init(array: MLMultiArray, name: String, expectedShape: [Int]) throws {
        let actualShape = array.shape.map(\.intValue)
        guard actualShape == expectedShape else {
            throw MangaVisionV2B5Error.outputShape(
                name: name,
                actual: actualShape,
                expected: expectedShape
            )
        }
        guard array.dataType == .float32 else {
            throw MangaVisionV2B5Error.unsupportedOutputDataType(
                name: name,
                actual: String(describing: array.dataType)
            )
        }
        let actualStrides = array.strides.map(\.intValue)
        guard actualStrides.count == expectedShape.count,
              actualStrides.allSatisfy({ $0 >= 0 }) else {
            throw MangaVisionV2B5Error.invalidInput(
                "invalid strides for \(name): \(actualStrides)"
            )
        }
        storage = array
        pointer = UnsafeRawPointer(array.dataPointer)
        strides = actualStrides
    }

    @inline(__always)
    func value(channel: Int, y: Int, x: Int) -> Float {
        // The decoder only consumes batch 0; do not add the batch stride for
        // that fixed index.
        let elementOffset = channel * strides[1] + y * strides[2] + x * strides[3]
        return pointer.load(fromByteOffset: elementOffset * MemoryLayout<Float32>.stride, as: Float32.self)
    }
}

nonisolated enum MangaVisionV2B5Decoder {
    static let scoreThreshold: Float = 0.05
    static let maxDetections = 300
    static let nmsThresholds: [Float] = [0.50, 0.55, 0.45, 0.55, 0.45]

    static func decode(
        rawOutputs: [String: MLMultiArray],
        sourceSize: CGSize,
        letterbox: MangaVisionV2B5Letterbox
    ) throws -> [MangaVisionV2B5Detection] {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw MangaVisionV2B5Error.invalidInput("empty source size")
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(1_024)
        for level in ["p2", "p3", "p4", "p5"] {
            guard let clsSpec = MangaVisionV2B5OutputContract.specs.first(where: {
                $0.level == level && $0.role == "classification"
            }),
            let bboxSpec = MangaVisionV2B5OutputContract.specs.first(where: {
                $0.level == level && $0.role == "bbox"
            }),
            let centerSpec = MangaVisionV2B5OutputContract.specs.first(where: {
                $0.level == level && $0.role == "centerness"
            }),
            let cls = rawOutputs[clsSpec.outputName],
            let bbox = rawOutputs[bboxSpec.outputName],
            let center = rawOutputs[centerSpec.outputName] else {
                throw MangaVisionV2B5Error.missingOutput(level)
            }
            let clsReader = try MangaVisionV2B5TensorReader(
                array: cls,
                name: "\(level).classification",
                expectedShape: [1, clsSpec.channels, clsSpec.height, clsSpec.width]
            )
            let bboxReader = try MangaVisionV2B5TensorReader(
                array: bbox,
                name: "\(level).bbox",
                expectedShape: [1, bboxSpec.channels, bboxSpec.height, bboxSpec.width]
            )
            let centerReader = try MangaVisionV2B5TensorReader(
                array: center,
                name: "\(level).centerness",
                expectedShape: [1, centerSpec.channels, centerSpec.height, centerSpec.width]
            )

            for y in 0..<clsSpec.height {
                for x in 0..<clsSpec.width {
                    let centerness = sigmoid(centerReader.value(channel: 0, y: y, x: x))
                    var bestScore: Float = 0
                    var bestClass = 0
                    for classID in 0..<MangaVisionV2B5ClassOrder.regionTypes.count {
                        let classification = sigmoid(clsReader.value(channel: classID, y: y, x: x))
                        let score = sqrt(max(classification * centerness, 0))
                        if score > bestScore {
                            bestScore = score
                            bestClass = classID
                        }
                    }
                    guard bestScore >= scoreThreshold else { continue }
                    let pointX = (Float(x) + 0.5) * Float(clsSpec.stride)
                    let pointY = (Float(y) + 0.5) * Float(clsSpec.stride)
                    let left = softplus(bboxReader.value(channel: 0, y: y, x: x)) * Float(clsSpec.stride)
                    let top = softplus(bboxReader.value(channel: 1, y: y, x: x)) * Float(clsSpec.stride)
                    let right = softplus(bboxReader.value(channel: 2, y: y, x: x)) * Float(clsSpec.stride)
                    let bottom = softplus(bboxReader.value(channel: 3, y: y, x: x)) * Float(clsSpec.stride)
                    let inputRect = CGRect(
                        x: CGFloat(max(pointX - left, 0)),
                        y: CGFloat(max(pointY - top, 0)),
                        width: CGFloat(max(min(pointX + right, 640) - max(pointX - left, 0), 0)),
                        height: CGFloat(max(min(pointY + bottom, 640) - max(pointY - top, 0), 0))
                    )
                    let normalized = letterbox.sourceNormalizedRect(fromInputRect: inputRect)
                    guard normalized.width > 0, normalized.height > 0 else { continue }
                    candidates.append(Candidate(
                        rect: normalized,
                        score: bestScore,
                        classID: bestClass,
                        level: level
                    ))
                }
            }
        }

        // Match the frozen Python decoder's pre-NMS cap: top max_detections * 4
        // candidates globally, then class-aware NMS and a final global cap.
        if candidates.count > maxDetections * 4 {
            candidates = candidates.sorted(by: Candidate.preferred).prefix(maxDetections * 4).map { $0 }
        }

        var kept: [Candidate] = []
        for classID in MangaVisionV2B5ClassOrder.regionTypes.indices {
            let classCandidates = candidates.enumerated()
                .filter { $0.element.classID == classID }
                .sorted { Candidate.preferred($0.element, $1.element) }
            var keptIndices: [Int] = []
            for (originalIndex, candidate) in classCandidates {
                guard !keptIndices.contains(where: {
                    intersectionOverUnion(candidate.rect, candidates[$0].rect)
                        > CGFloat(nmsThresholds[classID])
                }) else { continue }
                keptIndices.append(originalIndex)
            }
            kept.append(contentsOf: keptIndices.map { candidates[$0] })
        }

        return kept.sorted(by: Candidate.preferred)
            .prefix(maxDetections)
            .map { candidate in
                MangaVisionV2B5Detection(
                    type: MangaVisionV2B5ClassOrder.regionTypes[candidate.classID],
                    normalizedRect: candidate.rect,
                    confidence: candidate.score,
                    pyramidLevel: candidate.level
                )
            }
    }

    static func regions(
        from detections: [MangaVisionV2B5Detection]
    ) -> [MangaVisionRegion] {
        detections.map {
            MangaVisionRegion(
                type: $0.type,
                normalizedRect: $0.normalizedRect,
                confidence: $0.confidence
            )
        }
    }

    private struct Candidate {
        let rect: CGRect
        let score: Float
        let classID: Int
        let level: String

        static func preferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.classID != rhs.classID { return lhs.classID < rhs.classID }
            return lhs.level < rhs.level
        }
    }

    private static func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            let exponential = exp(-value)
            return 1 / (1 + exponential)
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }

    private static func softplus(_ value: Float) -> Float {
        value > 20 ? value : log1p(exp(value))
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = max(intersection.width, 0) * max(intersection.height, 0)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return intersectionArea / max(union, 0.000_001)
    }
}

nonisolated enum MangaVisionV2B5ProductionIdentity {
    static let modelName = "MangaVisionDetectorV2B5"
    static let coreMLTreeSHA256 = "ebde3f514e2fb84e48f73bd194041da671337f7b770e3baeae637ed8c5dba4c5"
    static let calibrationRevision = "v2b5-calibration-v1"
}

actor MangaVisionV2B5Provider: MangaVisionProvider, MangaVisionRuntimeReleasable {
    static let shared = MangaVisionV2B5Provider()
    static let modelResourceName = "MangaVisionV2B5"
    static let modelIdentifier = "manga-vision-v2b5-coreml-fp32-640"

    private struct Runtime {
        let model: MLModel
        let descriptor: MangaVisionProviderDescriptor
    }

    private var runtime: Runtime?
    private var measuredColdLoadMilliseconds: Double?
    private var runtimeLoadCount = 0
    private var mainThreadExecutionObserved = false

    var descriptor: MangaVisionProviderDescriptor {
        get async {
            if let runtime { return runtime.descriptor }
            if let runtime = try? loadRuntime() { return runtime.descriptor }
            return Self.fallbackDescriptor
        }
    }

    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis {
        try await analyzePageWithTiming(
            image: image,
            sourceImageSize: sourceImageSize,
            pageIdentifier: pageIdentifier
        ).analysis
    }

    func analyzePageWithTiming(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaVisionTimedAnalysis {
        noteMainThreadExecutionIfNeeded()
        let totalStart = ContinuousClock.now
        let runtime = try loadRuntime()
        let preprocessStart = ContinuousClock.now
        let prepared = try MangaVisionV2B5Preprocessor.makeInput(from: image)
        let preprocessMilliseconds = Self.milliseconds(preprocessStart.duration(to: .now))
        let input = try MLDictionaryFeatureProvider(dictionary: [
            MangaVisionV2B5OutputContract.inputFeatureName: MLFeatureValue(multiArray: prepared.array)
        ])
        let modelStart = ContinuousClock.now
        // Keep the non-Sendable MLModel actor-isolated. Core ML's batch API is
        // synchronous, so a one-item batch performs the same inference without sending
        // the model across an async isolation boundary or weakening Sendable checking.
        let predictionBatch = try runtime.model.predictions(
            fromBatch: MLArrayBatchProvider(array: [input])
        )
        guard predictionBatch.count == 1 else {
            throw MangaVisionV2B5Error.invalidInput(
                "unexpected Core ML batch output count=\(predictionBatch.count)"
            )
        }
        let prediction = predictionBatch.features(at: 0)
        let modelMilliseconds = Self.milliseconds(modelStart.duration(to: .now))
        let postprocessStart = ContinuousClock.now
        let rawOutputs = try MangaVisionV2B5OutputContract.rawOutputs(from: prediction)
        let detections = try MangaVisionV2B5Decoder.decode(
            rawOutputs: rawOutputs,
            sourceSize: CGSize(width: image.width, height: image.height),
            letterbox: prepared.letterbox
        )
        let grouped = Dictionary(grouping: detections, by: \.type)
        let analysis = MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: MangaVisionV2B5Decoder.regions(from: grouped[.panel] ?? []),
            texts: MangaVisionV2B5Decoder.regions(from: grouped[.text] ?? []),
            balloons: MangaVisionV2B5Decoder.regions(from: grouped[.balloon] ?? []),
            faces: MangaVisionV2B5Decoder.regions(from: grouped[.face] ?? []),
            bodies: MangaVisionV2B5Decoder.regions(from: grouped[.body] ?? []),
            modelIdentifier: runtime.descriptor.modelIdentifier,
            modelVersion: runtime.descriptor.modelVersion
        )
        return MangaVisionTimedAnalysis(
            analysis: analysis,
            timing: MangaVisionProviderTiming(
                preprocessMilliseconds: preprocessMilliseconds,
                modelMilliseconds: modelMilliseconds,
                postprocessMilliseconds: Self.milliseconds(postprocessStart.duration(to: .now)),
                totalMilliseconds: Self.milliseconds(totalStart.duration(to: .now))
            )
        )
    }

    func coldLoadMillisecondsForDiagnostics() -> Double? {
        measuredColdLoadMilliseconds
    }

    func runtimeLoadCountForDiagnostics() -> Int {
        runtimeLoadCount
    }

    func mainThreadExecutionObservedForDiagnostics() -> Bool {
        mainThreadExecutionObserved
    }

    func runtimeIsLoadedForDiagnostics() -> Bool {
        runtime != nil
    }

    func releaseRuntimeMemory() async {
        guard runtime != nil else { return }
        runtime = nil
        MReaderLog.reader.notice("Manga Vision Core ML runtime released")
    }

    private func loadRuntime() throws -> Runtime {
        if let runtime { return runtime }
        noteMainThreadExecutionIfNeeded()
        let started = ContinuousClock.now
        guard let modelURL = Bundle.main.url(
            forResource: Self.modelResourceName,
            withExtension: "mlmodelc"
        ) else {
            throw MangaVisionV2B5Error.modelUnavailable
        }
        let configuration = MLModelConfiguration()
        // Initial integration intentionally uses all available compute units; the
        // physical device benchmark decides whether a later policy is justified.
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let violations = MangaVisionV2B5OutputContract.validate(modelDescription: model.modelDescription)
        guard violations.isEmpty else {
            throw MangaVisionV2B5Error.invalidContract(violations)
        }
        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: Self.modelIdentifier,
            modelVersion: 5,
            inputSize: MangaVisionV2B5Preprocessor.inputSize,
            supportedRegionTypes: Set(MangaVisionV2B5ClassOrder.regionTypes)
        )
        let loaded = Runtime(model: model, descriptor: descriptor)
        runtime = loaded
        runtimeLoadCount += 1
        measuredColdLoadMilliseconds = Self.milliseconds(started.duration(to: .now))
        return loaded
    }

    private func noteMainThreadExecutionIfNeeded() {
        if Thread.isMainThread {
            mainThreadExecutionObserved = true
        }
    }

    private static let fallbackDescriptor = MangaVisionProviderDescriptor(
        modelIdentifier: MangaVisionV2B5Provider.modelIdentifier,
        modelVersion: 5,
        inputSize: MangaVisionV2B5Preprocessor.inputSize,
        supportedRegionTypes: Set(MangaVisionV2B5ClassOrder.regionTypes)
    )

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

extension MangaVisionV2B5Provider: MangaVisionManifestProviding {
    nonisolated func mangaVisionManifest() async -> MangaVisionModelManifest {
        MangaVisionModelManifest.bundledV2B5()
    }
}

extension MangaVisionModelManifest {
    nonisolated static func bundledV2B5(bundle: Bundle = .main) -> MangaVisionModelManifest {
        let resourceName = MangaVisionV2B5Provider.modelResourceName
        let compiledURL = bundle.url(forResource: resourceName, withExtension: "mlmodelc")
        let fileHash = compiledURL.flatMap(Self.hashModelDirectoryForDiagnostics)
            ?? "missing:\(resourceName)"
        let buildID = fileHash == "missing:\(resourceName)"
            ? fileHash
            : "sha256:\(fileHash.prefix(20))"
        return MangaVisionModelManifest(
            modelID: MangaVisionV2B5Provider.modelIdentifier,
            modelVersion: 5,
            modelBuildID: buildID,
            modelFileHash: fileHash,
            inputSize: MangaVisionV2B5Preprocessor.inputSize,
            semanticClasses: Set(MangaVisionV2B5ClassOrder.regionTypes),
            outputContractRevision: MangaVisionV2B5OutputContract.revision,
            analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
            postProcessRevision: "manga-vision-v2b5-fcos-postprocess-v1",
            calibrationRevision: MangaVisionV2B5ProductionIdentity.calibrationRevision
        )
    }
}
