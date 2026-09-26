import CoreGraphics
import CoreML
import Foundation
import os

/// The frozen class order of the bundled Koharu YOLO26s-seg checkpoint.
/// The raw names come from `models/koharu-yolo26s/config.json`.
nonisolated enum MangaVisionKoharuClassOrder {
    static let labels = ["frame", "dialogue_text", "balloon", "onomatopoeia_text"]
    static let regionTypes: [MangaRegionType] = [.panel, .text, .balloon, .onomatopoeia]

    static func regionType(forModelClassIndex index: Int) -> MangaRegionType? {
        guard regionTypes.indices.contains(index) else { return nil }
        return regionTypes[index]
    }
}

nonisolated struct MangaVisionKoharuLetterbox: Sendable, Equatable {
    let scale: CGFloat
    let paddingXY: CGPoint
    let originalSize: CGSize
    let inputSize: CGSize

    /// Mirrors the ultralytics `LetterBox` contract used to train and export the
    /// checkpoint: `scaleup`, centered gray padding, and `round(d - 0.1)` origins.
    static func make(
        sourceSize: CGSize,
        inputSize: CGSize = MangaVisionKoharuOutputContract.inputSize
    ) -> Self {
        let sourceWidth = max(sourceSize.width, 1)
        let sourceHeight = max(sourceSize.height, 1)
        let scale = min(inputSize.width / sourceWidth, inputSize.height / sourceHeight)
        let resizedWidth = max((sourceWidth * scale).rounded(), 1)
        let resizedHeight = max((sourceHeight * scale).rounded(), 1)
        return Self(
            scale: scale,
            paddingXY: CGPoint(
                x: ((inputSize.width - resizedWidth) / 2 - 0.1).rounded(),
                y: ((inputSize.height - resizedHeight) / 2 - 0.1).rounded()
            ),
            originalSize: CGSize(width: sourceWidth, height: sourceHeight),
            inputSize: inputSize
        )
    }

    /// Converts a rectangle in letterboxed model-input pixels back to page-normalized
    /// coordinates, using the same `(value - padding) / gain` transform as the
    /// ultralytics box decoder.
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

    /// Converts a point in letterboxed model-input pixels back to page-normalized
    /// coordinates. Contour vertices use this form so a degenerate rect never has to
    /// survive rectangle clamping.
    func sourceNormalizedPoint(fromInputPoint point: CGPoint) -> CGPoint {
        let scaledWidth = max(originalSize.width * scale, 1)
        let scaledHeight = max(originalSize.height * scale, 1)
        return MangaPageCoordinateSpace.clampedNormalizedPoint(CGPoint(
            x: (point.x - paddingXY.x) / scaledWidth,
            y: (point.y - paddingXY.y) / scaledHeight
        ))
    }

    /// Maps a page-normalized rectangle into model-input pixel space. Used to bound the
    /// mask decode to the pixels that can belong to a detection.
    func inputRect(fromSourceNormalizedRect rect: CGRect) -> CGRect {
        CGRect(
            x: paddingXY.x + rect.minX * originalSize.width * scale,
            y: paddingXY.y + rect.minY * originalSize.height * scale,
            width: rect.width * originalSize.width * scale,
            height: rect.height * originalSize.height * scale
        )
    }
}

nonisolated enum MangaVisionKoharuOutputContract {
    static let revision = "manga-vision-koharu-yolo26s-end2end-output-v1"
    static let inputFeatureName = "image"
    static let inputSize = CGSize(width: 1280, height: 1280)
    static let detectionsFeatureName = "detections"
    static let protosFeatureName = "protos"

    /// `[x1, y1, x2, y2, confidence, classIndex, maskCoefficient x 32]` in input pixels.
    static let detectionsShape = [1, 300, 38]
    /// Mask prototypes at 1/4 of the model input resolution.
    static let protosShape = [1, 32, 320, 320]
    static let geometryChannelCount = 6
    static let maskCoefficientCount = 32
    /// `protos` spatial size relative to the model input.
    static let maskPrototypeStride = 4

    static var outputNames: Set<String> {
        [detectionsFeatureName, protosFeatureName]
    }

    static func validate(modelDescription: MLModelDescription) -> [String] {
        var violations: [String] = []
        guard let input = modelDescription.inputDescriptionsByName[inputFeatureName] else {
            return ["missing-input:\(inputFeatureName)"]
        }
        guard input.type == .image, let imageConstraint = input.imageConstraint else {
            violations.append("input-is-not-image")
            return violations
        }
        let expectedPixels = Int(inputSize.width) * Int(inputSize.height)
        if imageConstraint.pixelsWide * imageConstraint.pixelsHigh != expectedPixels {
            violations.append(
                "input-image-size:\(imageConstraint.pixelsWide)x\(imageConstraint.pixelsHigh)"
            )
        }

        let outputs = modelDescription.outputDescriptionsByName
        let missing = outputNames.subtracting(outputs.keys).sorted()
        let extra = Set(outputs.keys).subtracting(outputNames).sorted()
        if !missing.isEmpty { violations.append("missing-outputs:\(missing.joined(separator: ","))") }
        if !extra.isEmpty { violations.append("unexpected-outputs:\(extra.joined(separator: ","))") }

        for (name, expected) in [
            (detectionsFeatureName, detectionsShape),
            (protosFeatureName, protosShape)
        ] {
            guard let description = outputs[name] else { continue }
            guard description.type == .multiArray,
                  let shape = description.multiArrayConstraint?.shape.map(\.intValue) else {
                violations.append("output-not-multiarray:\(name)")
                continue
            }
            if shape != expected {
                violations.append("output-shape:\(name)=\(shape),expected=\(expected)")
            }
        }
        return violations
    }
}

nonisolated enum MangaVisionKoharuError: Error, Sendable, Equatable {
    case modelUnavailable
    case invalidContract([String])
    case missingOutput(String)
    case outputShape(name: String, actual: [Int], expected: [Int])
    case invalidInput(String)
    case unsupportedOutputDataType(name: String, actual: String)
    case missingImageConstraint(String)
}

/// Validated, stride-aware float32 view over one Core ML output tensor.
///
/// The decoder performs millions of scalar reads per page. `MLMultiArray` subscripting
/// allocates an `NSNumber` index array per read, so the reader keeps the array alive
/// and reads its validated Float32 storage directly. Offsets use the runtime-provided
/// strides and never assume a contiguous tensor.
///
/// The two bundled tensors have different ranks: `detections` is `[1, rows, channels]`
/// and `protos` is `[1, channels, height, width]`. Each gets its own accessor so no
/// caller can index past the stride array, and batch index 0 is always folded into the
/// base offset by simply not adding `strides[0]`.
nonisolated struct MangaVisionKoharuTensorReader {
    private let storage: MLMultiArray
    private let pointer: UnsafeRawPointer
    private let strides: [Int]
    let shape: [Int]

    init(array: MLMultiArray, name: String, expectedShape: [Int]) throws {
        shape = array.shape.map(\.intValue)
        guard shape == expectedShape else {
            throw MangaVisionKoharuError.outputShape(
                name: name,
                actual: shape,
                expected: expectedShape
            )
        }
        guard array.dataType == .float32 else {
            throw MangaVisionKoharuError.unsupportedOutputDataType(
                name: name,
                actual: String(describing: array.dataType)
            )
        }
        let actualStrides = array.strides.map(\.intValue)
        guard actualStrides.count == expectedShape.count,
              actualStrides.allSatisfy({ $0 >= 0 }) else {
            throw MangaVisionKoharuError.invalidInput("invalid strides for \(name): \(actualStrides)")
        }
        storage = array
        pointer = UnsafeRawPointer(array.dataPointer)
        strides = actualStrides
    }

    @inline(__always)
    private func load(_ elementOffset: Int) -> Float {
        pointer.load(fromByteOffset: elementOffset * MemoryLayout<Float32>.stride, as: Float32.self)
    }

    /// Rank-3 accessor for `detections` (`[1, rows, channels]`).
    @inline(__always)
    func detection(row: Int, channel: Int) -> Float {
        let rank = shape.count
        return load(row * strides[rank - 2] + channel * strides[rank - 1])
    }

    /// Rank-4 accessor for `protos` (`[1, channels, height, width]`).
    @inline(__always)
    func prototype(channel: Int, y: Int, x: Int) -> Float {
        let rank = shape.count
        return load(
            channel * strides[rank - 3] + y * strides[rank - 2] + x * strides[rank - 1]
        )
    }
}

/// One decoded detection, still in page-normalized coordinates.
nonisolated struct MangaVisionKoharuDetection: Sendable, Equatable {
    let type: MangaRegionType
    let normalizedRect: CGRect
    let confidence: Float
    let contour: MangaVisionContour?
}

nonisolated enum MangaVisionKoharuDecoder {
    /// The checkpoint's own recommended operating point (`config.json` / model card).
    static let scoreThreshold: Float = 0.25
    static let maximumDetections = 300
    /// Mask probability above which a prototype pixel belongs to the instance.
    /// Strictly greater: `sigmoid(0) == 0.5` must not count as foreground, which is
    /// exactly what an all-zero coefficient/prototype pair produces.
    static let maskProbabilityThreshold: Float = 0.5
    /// Rows sampled across a mask outline. Two vertices per row (left edge, then right
    /// edge) keeps the finished contour at `MangaVisionContour.maximumPointCount`.
    static let contourSampleRowCount = MangaVisionContour.maximumPointCount / 2
    private static let minimumMaskPixelCount = 12

    static func decode(
        detections: MangaVisionKoharuTensorReader,
        protos: MangaVisionKoharuTensorReader,
        letterbox: MangaVisionKoharuLetterbox
    ) throws -> [MangaVisionKoharuDetection] {
        let inputWidth = Int(MangaVisionKoharuOutputContract.inputSize.width)
        let inputHeight = Int(MangaVisionKoharuOutputContract.inputSize.height)
        let prototypeWidth = protos.shape[3]
        let prototypeHeight = protos.shape[2]

        var results: [MangaVisionKoharuDetection] = []
        results.reserveCapacity(64)

        // The end-to-end head is NMS-free: it already ranks and de-duplicates its
        // output rows, so the decoder filters by confidence and never runs IoU NMS.
        for row in 0..<detections.shape[1] {
            guard results.count < maximumDetections else { break }
            let confidence = detections.detection(row: row, channel: 4)
            guard confidence >= scoreThreshold else { continue }
            let classIndex = Int(detections.detection(row: row, channel: 5).rounded())
            guard let regionType = MangaVisionKoharuClassOrder
                .regionType(forModelClassIndex: classIndex) else {
                continue
            }

            let x1 = CGFloat(detections.detection(row: row, channel: 0))
            let y1 = CGFloat(detections.detection(row: row, channel: 1))
            let x2 = CGFloat(detections.detection(row: row, channel: 2))
            let y2 = CGFloat(detections.detection(row: row, channel: 3))
            let inputRect = CGRect(
                x: max(min(x1, x2), 0),
                y: max(min(y1, y2), 0),
                width: max(abs(x2 - x1), 0),
                height: max(abs(y2 - y1), 0)
            ).intersection(CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
            guard inputRect.width >= 1, inputRect.height >= 1 else { continue }

            let normalized = letterbox.sourceNormalizedRect(fromInputRect: inputRect)
            guard normalized.width > 0, normalized.height > 0 else { continue }

            results.append(MangaVisionKoharuDetection(
                type: regionType,
                normalizedRect: normalized,
                confidence: confidence,
                contour: contour(
                    forRow: row,
                    detections: detections,
                    protos: protos,
                    inputRect: inputRect,
                    letterbox: letterbox,
                    prototypeWidth: prototypeWidth,
                    prototypeHeight: prototypeHeight
                )
            ))
        }
        return results
    }

    static func regions(
        from detections: [MangaVisionKoharuDetection]
    ) -> [MangaVisionRegion] {
        detections.map {
            MangaVisionRegion(
                type: $0.type,
                normalizedRect: $0.normalizedRect,
                confidence: $0.confidence,
                contour: $0.contour
            )
        }
    }

    /// Decodes one instance mask and distils it into a compact normalized outline.
    ///
    /// Masks are only evaluated inside the detection's own box, so a page with many
    /// detections still performs a small, bounded amount of work.
    private static func contour(
        forRow row: Int,
        detections: MangaVisionKoharuTensorReader,
        protos: MangaVisionKoharuTensorReader,
        inputRect: CGRect,
        letterbox: MangaVisionKoharuLetterbox,
        prototypeWidth: Int,
        prototypeHeight: Int
    ) -> MangaVisionContour? {
        let inputPixelsPerPrototypeX =
            MangaVisionKoharuOutputContract.inputSize.width / CGFloat(prototypeWidth)
        let inputPixelsPerPrototypeY =
            MangaVisionKoharuOutputContract.inputSize.height / CGFloat(prototypeHeight)

        let rawBox = CGRect(
            x: inputRect.minX / inputPixelsPerPrototypeX,
            y: inputRect.minY / inputPixelsPerPrototypeY,
            width: inputRect.width / inputPixelsPerPrototypeX,
            height: inputRect.height / inputPixelsPerPrototypeY
        ).integral
        let box = rawBox.intersection(
            CGRect(x: 0, y: 0, width: prototypeWidth, height: prototypeHeight)
        )
        // A null intersection would make `Int(box.minX)` trap on infinity; the caller
        // already clips to the input bounds, but a mask decode must never be able to
        // crash the detector.
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let startX = Int(box.minX)
        let startY = Int(box.minY)
        let endX = min(Int(box.maxX), prototypeWidth)
        let endY = min(Int(box.maxY), prototypeHeight)
        let regionWidth = endX - startX
        let regionHeight = endY - startY
        guard regionWidth > 1, regionHeight > 1 else { return nil }

        let coefficientCount = MangaVisionKoharuOutputContract.maskCoefficientCount
        var coefficients = [Float](repeating: 0, count: coefficientCount)
        for index in 0..<coefficientCount {
            coefficients[index] = detections.detection(row: row, channel: 6 + index)
        }

        var mask = [Float](repeating: 0, count: regionWidth * regionHeight)
        var activePixelCount = 0
        for y in 0..<regionHeight {
            for x in 0..<regionWidth {
                var accumulator: Float = 0
                for channel in 0..<coefficientCount {
                    accumulator += coefficients[channel]
                        * protos.prototype(channel: channel, y: startY + y, x: startX + x)
                }
                let probability = sigmoid(accumulator)
                mask[y * regionWidth + x] = probability
                if probability > maskProbabilityThreshold { activePixelCount += 1 }
            }
        }
        guard activePixelCount >= minimumMaskPixelCount else { return nil }

        // Row extents give a cheap, stable outline for both rectangular panels and
        // rounded balloons, and are far cheaper than boundary tracing.
        var rows: [Int] = []
        var leftEdges: [Int] = []
        var rightEdges: [Int] = []
        rows.reserveCapacity(regionHeight)
        for y in 0..<regionHeight {
            var left = Int.max
            var right = Int.min
            for x in 0..<regionWidth where mask[y * regionWidth + x] > maskProbabilityThreshold {
                if x < left { left = x }
                if x > right { right = x }
            }
            guard right >= left else { continue }
            rows.append(y)
            leftEdges.append(left)
            rightEdges.append(right)
        }
        guard rows.count >= 2 else { return nil }

        let sampleCount = min(contourSampleRowCount, rows.count)
        let step = Double(rows.count) / Double(sampleCount)
        var leftPoints: [CGPoint] = []
        var rightPoints: [CGPoint] = []
        leftPoints.reserveCapacity(sampleCount)
        rightPoints.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let position = min(Int((Double(index) * step).rounded(.down)), rows.count - 1)
            let y = rows[position]
            let left = CGPoint(
                x: CGFloat(startX + leftEdges[position]) * inputPixelsPerPrototypeX,
                y: CGFloat(startY + y) * inputPixelsPerPrototypeY
            )
            // The right vertex is offset by one prototype pixel so the ring encloses
            // the final masked pixel instead of cutting through its center.
            let right = CGPoint(
                x: CGFloat(startX + rightEdges[position] + 1) * inputPixelsPerPrototypeX,
                y: CGFloat(startY + y + 1) * inputPixelsPerPrototypeY
            )
            leftPoints.append(letterbox.sourceNormalizedPoint(fromInputPoint: left))
            rightPoints.append(letterbox.sourceNormalizedPoint(fromInputPoint: right))
        }
        guard leftPoints.count >= 2, rightPoints.count >= 2 else { return nil }

        // Walk the left edge downwards, then the right edge upwards, to close the ring.
        return MangaVisionContour(points: leftPoints + rightPoints.reversed())
    }

    @inline(__always)
    private static func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            return 1 / (1 + exp(-value))
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }
}

nonisolated enum MangaVisionKoharuProductionIdentity {
    static let modelName = "KoharuYOLO26S"
    static let calibrationRevision = "koharu-yolo26s-seg-calibration-2026-09-27-v1"
}

nonisolated struct MangaVisionKoharuPreparedInput {
    let image: CGImage
    let letterbox: MangaVisionKoharuLetterbox
}

/// Explicit, model-faithful preprocessing for the Koharu YOLO26s-seg export.
///
/// The contract is the ultralytics `LetterBox` transform the checkpoint was trained
/// with: an aspect-preserving resize onto a 1280x1280 canvas, centered padding filled
/// with gray 114, and no mean/std normalization. The only scaling step is the model's
/// own `1/255`.
///
/// The resize reproduces OpenCV's `INTER_LINEAR` kernel — half-pixel sample centers,
/// two taps, and an 11-bit fixed-point accumulator with round-half-up — because the
/// exported checkpoint was validated against that kernel. Core Graphics'
/// platform-dependent interpolation is deliberately not used: it changes borderline
/// detections.
nonisolated enum MangaVisionKoharuPreprocessor {
    static let inputSize = MangaVisionKoharuOutputContract.inputSize
    /// Ultralytics pads with 114 rather than white; a white border reads as page art.
    static let paddingValue: UInt8 = 114
    private static let interpolationPrecisionBits = 11
    private static let interpolationScale = 1 << interpolationPrecisionBits

    static func makeInput(from image: CGImage) throws -> MangaVisionKoharuPreparedInput {
        guard image.width > 0, image.height > 0 else {
            throw MangaVisionKoharuError.invalidInput("empty CGImage")
        }
        let sourceSize = CGSize(width: image.width, height: image.height)
        let letterbox = MangaVisionKoharuLetterbox.make(sourceSize: sourceSize, inputSize: inputSize)
        let inputWidth = Int(inputSize.width)
        let inputHeight = Int(inputSize.height)
        let resizedWidth = max(Int((sourceSize.width * letterbox.scale).rounded()), 1)
        let resizedHeight = max(Int((sourceSize.height * letterbox.scale).rounded()), 1)

        let sourcePixels = try rgbaPixels(of: image)
        // The adaptive layer already bounds the source to the model input size, so the
        // resize is normally an identity and is skipped rather than re-sampled.
        let resized: [UInt8]
        if resizedWidth == image.width, resizedHeight == image.height {
            resized = sourcePixels
        } else {
            resized = bilinearResize(
                rgba: sourcePixels,
                sourceWidth: image.width,
                sourceHeight: image.height,
                destinationWidth: resizedWidth,
                destinationHeight: resizedHeight
            )
        }

        // Build the canvas in top-left row order, matching the layout Core ML expects
        // from an upright image feature.
        let originX = Int(letterbox.paddingXY.x)
        let originY = Int(letterbox.paddingXY.y)
        let padding = paddingValue
        var canvas = [UInt8](repeating: 0, count: inputWidth * inputHeight * 4)
        for index in stride(from: 0, to: canvas.count, by: 4) {
            canvas[index] = padding
            canvas[index + 1] = padding
            canvas[index + 2] = padding
            canvas[index + 3] = 255
        }
        for y in 0..<resizedHeight {
            let destinationY = originY + y
            guard destinationY >= 0, destinationY < inputHeight else { continue }
            for x in 0..<resizedWidth {
                let destinationX = originX + x
                guard destinationX >= 0, destinationX < inputWidth else { continue }
                let sourceOffset = (y * resizedWidth + x) * 3
                let destinationOffset = (destinationY * inputWidth + destinationX) * 4
                canvas[destinationOffset] = resized[sourceOffset]
                canvas[destinationOffset + 1] = resized[sourceOffset + 1]
                canvas[destinationOffset + 2] = resized[sourceOffset + 2]
            }
        }

        guard let cgImage = makeCGImage(rgba: canvas, width: inputWidth, height: inputHeight) else {
            throw MangaVisionKoharuError.invalidInput("cannot build letterboxed canvas")
        }
        return MangaVisionKoharuPreparedInput(image: cgImage, letterbox: letterbox)
    }

    /// Draws the source into a tightly packed, top-left-origin RGBA8 buffer.
    private static func rgbaPixels(of image: CGImage) throws -> [UInt8] {
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
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            created = true
        }
        guard created else {
            throw MangaVisionKoharuError.invalidInput("cannot allocate RGB source canvas")
        }
        return pixels
    }

    private static func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Separable OpenCV `INTER_LINEAR` resize over an RGBA8 source, emitting RGB8.
    private static func bilinearResize(
        rgba: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> [UInt8] {
        let horizontalCoefficients = linearCoefficients(
            sourceSize: sourceWidth,
            destinationSize: destinationWidth
        )
        // Pass 1: horizontal. Source rows are preserved.
        var horizontal = [UInt8](repeating: 0, count: sourceHeight * destinationWidth * 3)
        for y in 0..<sourceHeight {
            let rowOffset = y * sourceWidth * 4
            for x in 0..<destinationWidth {
                let coefficient = horizontalCoefficients[x]
                let lowerOffset = rowOffset + coefficient.lowerIndex * 4
                let upperOffset = rowOffset + coefficient.upperIndex * 4
                let destinationOffset = (y * destinationWidth + x) * 3
                for channel in 0..<3 {
                    let accumulator = Int(rgba[lowerOffset + channel]) * coefficient.lowerWeight
                        + Int(rgba[upperOffset + channel]) * coefficient.upperWeight
                    horizontal[destinationOffset + channel] = clampedByte(
                        (accumulator + (interpolationScale / 2)) >> interpolationPrecisionBits
                    )
                }
            }
        }

        let verticalCoefficients = linearCoefficients(
            sourceSize: sourceHeight,
            destinationSize: destinationHeight
        )
        // Pass 2: vertical, over the already-resized rows.
        var output = [UInt8](repeating: 0, count: destinationHeight * destinationWidth * 3)
        for y in 0..<destinationHeight {
            let coefficient = verticalCoefficients[y]
            let lowerRow = coefficient.lowerIndex * destinationWidth * 3
            let upperRow = coefficient.upperIndex * destinationWidth * 3
            for x in 0..<destinationWidth {
                let destinationOffset = (y * destinationWidth + x) * 3
                for channel in 0..<3 {
                    let accumulator =
                        Int(horizontal[lowerRow + x * 3 + channel]) * coefficient.lowerWeight
                        + Int(horizontal[upperRow + x * 3 + channel]) * coefficient.upperWeight
                    output[destinationOffset + channel] = clampedByte(
                        (accumulator + (interpolationScale / 2)) >> interpolationPrecisionBits
                    )
                }
            }
        }
        return output
    }

    private struct LinearCoefficient {
        let lowerIndex: Int
        let upperIndex: Int
        let lowerWeight: Int
        let upperWeight: Int
    }

    private static func linearCoefficients(
        sourceSize: Int,
        destinationSize: Int
    ) -> [LinearCoefficient] {
        let scale = Double(sourceSize) / Double(destinationSize)
        return (0..<destinationSize).map { outputIndex in
            let sourcePosition = (Double(outputIndex) + 0.5) * scale - 0.5
            var lower = Int(sourcePosition.rounded(.down))
            var fraction = sourcePosition - Double(lower)
            if lower < 0 {
                lower = 0
                fraction = 0
            } else if lower >= sourceSize {
                lower = sourceSize - 1
                fraction = 0
            }
            var upper = lower + 1
            if upper >= sourceSize { upper = sourceSize - 1 }
            if lower > upper { lower = upper }
            let lowerWeight = Int(((1 - fraction) * Double(interpolationScale)).rounded())
            return LinearCoefficient(
                lowerIndex: lower,
                upperIndex: upper,
                lowerWeight: lowerWeight,
                upperWeight: interpolationScale - lowerWeight
            )
        }
    }

    @inline(__always)
    private static func clampedByte(_ value: Int) -> UInt8 {
        value <= 0 ? 0 : (value >= 255 ? 255 : UInt8(value))
    }
}

actor MangaVisionKoharuProvider: MangaVisionProvider, MangaVisionRuntimeReleasable {
    static let shared = MangaVisionKoharuProvider()
    static let modelResourceName = "KoharuYOLO26S"
    static let modelIdentifier = "manga-vision-koharu-yolo26s-coreml-fp32-1280"
    static let modelVersionNumber = 6

    private struct Runtime {
        let model: MLModel
        let inputConstraint: MLImageConstraint
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
        let prepared = try MangaVisionKoharuPreprocessor.makeInput(from: image)
        let preprocessMilliseconds = Self.milliseconds(preprocessStart.duration(to: .now))

        let input = try MLDictionaryFeatureProvider(dictionary: [
            MangaVisionKoharuOutputContract.inputFeatureName: try MLFeatureValue(
                cgImage: prepared.image,
                constraint: runtime.inputConstraint,
                options: nil
            )
        ])

        let modelStart = ContinuousClock.now
        // Core ML's batch API is synchronous, so a one-item batch performs the same
        // inference without sending the non-Sendable MLModel across an isolation
        // boundary or weakening Sendable checking.
        let predictionBatch = try runtime.model.predictions(
            fromBatch: MLArrayBatchProvider(array: [input])
        )
        guard predictionBatch.count == 1 else {
            throw MangaVisionKoharuError.invalidInput(
                "unexpected Core ML batch output count=\(predictionBatch.count)"
            )
        }
        let prediction = predictionBatch.features(at: 0)
        let modelMilliseconds = Self.milliseconds(modelStart.duration(to: .now))

        let postprocessStart = ContinuousClock.now
        guard let detectionsArray = prediction.featureValue(
            for: MangaVisionKoharuOutputContract.detectionsFeatureName
        )?.multiArrayValue else {
            throw MangaVisionKoharuError.missingOutput(
                MangaVisionKoharuOutputContract.detectionsFeatureName
            )
        }
        guard let protosArray = prediction.featureValue(
            for: MangaVisionKoharuOutputContract.protosFeatureName
        )?.multiArrayValue else {
            throw MangaVisionKoharuError.missingOutput(
                MangaVisionKoharuOutputContract.protosFeatureName
            )
        }
        let detections = try MangaVisionKoharuDecoder.decode(
            detections: MangaVisionKoharuTensorReader(
                array: detectionsArray,
                name: MangaVisionKoharuOutputContract.detectionsFeatureName,
                expectedShape: MangaVisionKoharuOutputContract.detectionsShape
            ),
            protos: MangaVisionKoharuTensorReader(
                array: protosArray,
                name: MangaVisionKoharuOutputContract.protosFeatureName,
                expectedShape: MangaVisionKoharuOutputContract.protosShape
            ),
            letterbox: prepared.letterbox
        )
        let grouped = Dictionary(grouping: detections, by: \.type)
        // The one-to-one head is trained to be duplicate-free, but that is a learned
        // property, not a guarantee: a page can produce two nearly identical rows for
        // one panel (observed at IoU ~0.97). The revisioned calibration profile is the
        // single source of truth for same-class de-duplication, so it is applied here
        // as well as in the adaptive merge instead of only at merge time.
        let profile = MangaVisionCalibrationProfile.bundled
        func regions(for type: MangaRegionType) -> [MangaVisionRegion] {
            profile.deduplicated(
                MangaVisionKoharuDecoder.regions(from: grouped[type] ?? []),
                type: type
            )
        }
        let analysis = MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: regions(for: .panel),
            texts: regions(for: .text),
            balloons: regions(for: .balloon),
            onomatopoeias: regions(for: .onomatopoeia),
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
        MReaderLog.reader.notice("Koharu YOLO26s Core ML runtime released")
    }

    private func loadRuntime() throws -> Runtime {
        if let runtime { return runtime }
        noteMainThreadExecutionIfNeeded()
        let started = ContinuousClock.now
        guard let modelURL = Bundle.main.url(
            forResource: Self.modelResourceName,
            withExtension: "mlmodelc"
        ) else {
            throw MangaVisionKoharuError.modelUnavailable
        }
        // The converted package is full FP32: an FP16 conversion corrupts the
        // end-to-end head's top-k index path. All compute units stay enabled so the
        // runtime can still select the GPU when the neural engine cannot host FP32.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let violations = MangaVisionKoharuOutputContract.validate(
            modelDescription: model.modelDescription
        )
        guard violations.isEmpty else {
            throw MangaVisionKoharuError.invalidContract(violations)
        }
        guard let inputConstraint = model.modelDescription
            .inputDescriptionsByName[MangaVisionKoharuOutputContract.inputFeatureName]?
            .imageConstraint else {
            throw MangaVisionKoharuError.missingImageConstraint(
                MangaVisionKoharuOutputContract.inputFeatureName
            )
        }
        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: Self.modelIdentifier,
            modelVersion: Self.modelVersionNumber,
            inputSize: MangaVisionKoharuPreprocessor.inputSize,
            supportedRegionTypes: Set(MangaVisionKoharuClassOrder.regionTypes)
        )
        let loaded = Runtime(
            model: model,
            inputConstraint: inputConstraint,
            descriptor: descriptor
        )
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
        modelIdentifier: MangaVisionKoharuProvider.modelIdentifier,
        modelVersion: MangaVisionKoharuProvider.modelVersionNumber,
        inputSize: MangaVisionKoharuPreprocessor.inputSize,
        supportedRegionTypes: Set(MangaVisionKoharuClassOrder.regionTypes)
    )

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

extension MangaVisionKoharuProvider: MangaVisionManifestProviding {
    nonisolated func mangaVisionManifest() async -> MangaVisionModelManifest {
        MangaVisionModelManifest.bundledKoharuYOLO26S()
    }
}

extension MangaVisionModelManifest {
    nonisolated static func bundledKoharuYOLO26S(
        bundle: Bundle = .main
    ) -> MangaVisionModelManifest {
        let resourceName = MangaVisionKoharuProvider.modelResourceName
        let compiledURL = bundle.url(forResource: resourceName, withExtension: "mlmodelc")
        let fileHash = compiledURL.flatMap(Self.hashModelDirectoryForDiagnostics)
            ?? "missing:\(resourceName)"
        let buildID = fileHash == "missing:\(resourceName)"
            ? fileHash
            : "sha256:\(fileHash.prefix(20))"
        return MangaVisionModelManifest(
            modelID: MangaVisionKoharuProvider.modelIdentifier,
            modelVersion: MangaVisionKoharuProvider.modelVersionNumber,
            modelBuildID: buildID,
            modelFileHash: fileHash,
            inputSize: MangaVisionKoharuPreprocessor.inputSize,
            semanticClasses: Set(MangaVisionKoharuClassOrder.regionTypes),
            outputContractRevision: MangaVisionKoharuOutputContract.revision,
            analysisSchemaRevision: "manga-page-analysis-v\(MangaPageAnalysis.schemaVersion)",
            postProcessRevision: "manga-vision-koharu-yolo26s-end2end-postprocess-v1",
            calibrationRevision: MangaVisionKoharuProductionIdentity.calibrationRevision
        )
    }
}
