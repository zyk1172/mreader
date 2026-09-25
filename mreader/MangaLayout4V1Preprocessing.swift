import CoreGraphics
import CoreML
import Foundation

nonisolated struct MangaLayout4V1Letterbox: Sendable, Equatable {
    static let modelSize: CGFloat = 640

    let originalWidth: Int
    let originalHeight: Int
    let scale: CGFloat
    let resizedWidth: Int
    let resizedHeight: Int
    let padLeft: Int
    let padTop: Int
    let padRight: Int
    let padBottom: Int

    var originalSize: CGSize {
        CGSize(width: originalWidth, height: originalHeight)
    }

    static func make(sourceWidth: Int, sourceHeight: Int) throws -> Self {
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw MangaLayout4V1Error.invalidInput("empty CGImage")
        }
        let scale = min(
            modelSize / CGFloat(sourceWidth),
            modelSize / CGFloat(sourceHeight)
        )
        // Python's round() uses ties-to-even. Keep that behavior explicit instead
        // of relying on Swift's default to-nearest-or-away-from-zero rule.
        let resizedWidth = max(
            Int((CGFloat(sourceWidth) * scale).rounded(.toNearestOrEven)),
            1
        )
        let resizedHeight = max(
            Int((CGFloat(sourceHeight) * scale).rounded(.toNearestOrEven)),
            1
        )
        let horizontalPadding = max(Int(modelSize) - resizedWidth, 0)
        let verticalPadding = max(Int(modelSize) - resizedHeight, 0)
        let padLeft = horizontalPadding / 2
        let padTop = verticalPadding / 2
        return Self(
            originalWidth: sourceWidth,
            originalHeight: sourceHeight,
            scale: scale,
            resizedWidth: resizedWidth,
            resizedHeight: resizedHeight,
            padLeft: padLeft,
            padTop: padTop,
            padRight: horizontalPadding - padLeft,
            padBottom: verticalPadding - padTop
        )
    }

    func sourceNormalizedRect(fromModelRect rawRect: CGRect) -> CGRect {
        let modelBounds = CGRect(x: 0, y: 0, width: Self.modelSize, height: Self.modelSize)
        let rect = rawRect.standardized.intersection(modelBounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return .zero }

        let sourceX1 = (rect.minX - CGFloat(padLeft)) / scale
        let sourceY1 = (rect.minY - CGFloat(padTop)) / scale
        let sourceX2 = (rect.maxX - CGFloat(padLeft)) / scale
        let sourceY2 = (rect.maxY - CGFloat(padTop)) / scale
        let source = CGRect(
            x: sourceX1 / CGFloat(originalWidth),
            y: sourceY1 / CGFloat(originalHeight),
            width: (sourceX2 - sourceX1) / CGFloat(originalWidth),
            height: (sourceY2 - sourceY1) / CGFloat(originalHeight)
        )
        return MangaPageCoordinateSpace.clampedNormalizedRect(source)
    }

    func sourceNormalizedPoint(fromModelPoint point: CGPoint) -> CGPoint {
        let x = (point.x - CGFloat(padLeft)) / scale / CGFloat(originalWidth)
        let y = (point.y - CGFloat(padTop)) / scale / CGFloat(originalHeight)
        return CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }

    func modelRect(fromSourceNormalizedRect rect: CGRect) -> CGRect {
        let safe = MangaPageCoordinateSpace.clampedNormalizedRect(rect)
        let x1 = safe.minX * CGFloat(originalWidth) * scale + CGFloat(padLeft)
        let y1 = safe.minY * CGFloat(originalHeight) * scale + CGFloat(padTop)
        let x2 = safe.maxX * CGFloat(originalWidth) * scale + CGFloat(padLeft)
        let y2 = safe.maxY * CGFloat(originalHeight) * scale + CGFloat(padTop)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

nonisolated struct MangaLayout4V1PreparedInput {
    let array: MLMultiArray
    let letterbox: MangaLayout4V1Letterbox
}

nonisolated enum MangaLayout4V1Preprocessor {
    static let inputSize = CGSize(width: 640, height: 640)

    /// Matches manga-layout4-training/src/manga_layout4/data.py validation preprocessing.
    ///
    /// The exported Core ML graph itself performs ImageNet normalization
    /// (x - mean) / std. Feeding already-normalized Swift pixels would normalize twice.
    /// Therefore this boundary emits RGB CHW Float32 in 0...1 with white letterbox padding.
    static func makeInput(from image: CGImage) throws -> MangaLayout4V1PreparedInput {
        let letterbox = try MangaLayout4V1Letterbox.make(
            sourceWidth: image.width,
            sourceHeight: image.height
        )
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
            throw MangaLayout4V1Error.invalidInput("cannot allocate RGB source canvas")
        }

        let resized = pillowBilinearResize(
            sourcePixels: sourcePixels,
            sourceWidth: image.width,
            sourceHeight: image.height,
            destinationWidth: letterbox.resizedWidth,
            destinationHeight: letterbox.resizedHeight
        )

        // PIL uses an RGB white canvas. Keep alpha only as temporary storage;
        // Core ML receives the three RGB planes below.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<letterbox.resizedHeight {
            for x in 0..<letterbox.resizedWidth {
                let sourceOffset = (y * letterbox.resizedWidth + x) * 3
                let destinationOffset = (
                    (letterbox.padTop + y) * width + letterbox.padLeft + x
                ) * 4
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

        let array = try MLMultiArray(
            shape: MangaLayout4V1OutputContract.inputShape.map(NSNumber.init),
            dataType: .float32
        )
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            array.dataPointer.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
        return MangaLayout4V1PreparedInput(array: array, letterbox: letterbox)
    }

    /// Integer fixed-point reproduction of Pillow's bilinear resize path already
    /// validated against the Python reference fixture. MangaLayout4 V1 uses the same PIL
    /// Image.Resampling.BILINEAR contract.
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

        let horizontalCoefficients = coefficients(
            sourceSize: sourceWidth,
            destinationSize: destinationWidth
        )
        let verticalCoefficients = coefficients(
            sourceSize: sourceHeight,
            destinationSize: destinationHeight
        )
        var horizontal = [UInt8](
            repeating: 0,
            count: sourceHeight * destinationWidth * 3
        )
        for y in 0..<sourceHeight {
            for x in 0..<destinationWidth {
                let coefficient = horizontalCoefficients[x]
                for channel in 0..<3 {
                    var accumulator = 1 << (precisionBits - 1)
                    for index in coefficient.weights.indices {
                        let sourceX = coefficient.start + index
                        guard sourceX < sourceWidth else { continue }
                        accumulator += Int(
                            sourcePixels[(y * sourceWidth + sourceX) * 4 + channel]
                        ) * coefficient.weights[index]
                    }
                    horizontal[(y * destinationWidth + x) * 3 + channel] = UInt8(
                        max(min(accumulator >> precisionBits, 255), 0)
                    )
                }
            }
        }

        var output = [UInt8](
            repeating: 0,
            count: destinationHeight * destinationWidth * 3
        )
        for y in 0..<destinationHeight {
            let coefficient = verticalCoefficients[y]
            for x in 0..<destinationWidth {
                for channel in 0..<3 {
                    var accumulator = 1 << (precisionBits - 1)
                    for index in coefficient.weights.indices {
                        let sourceY = coefficient.start + index
                        guard sourceY < sourceHeight else { continue }
                        accumulator += Int(
                            horizontal[(sourceY * destinationWidth + x) * 3 + channel]
                        ) * coefficient.weights[index]
                    }
                    output[(y * destinationWidth + x) * 3 + channel] = UInt8(
                        max(min(accumulator >> precisionBits, 255), 0)
                    )
                }
            }
        }
        return output
    }
}
