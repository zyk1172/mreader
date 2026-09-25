import CoreGraphics
import CoreML
import Foundation

/// Adapter-local binary mask at prototype resolution. Raw prototype/coefficient
/// tensors never cross this boundary into reader business logic.
nonisolated struct MangaLayout4V1BinaryMask: Sendable, Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> Bool {
        pixels[y * width + x] != 0
    }

    var foregroundPixelCount: Int {
        pixels.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
    }

    func intersectionOverUnion(with other: Self) -> Double {
        guard width == other.width, height == other.height else { return 0 }
        var intersection = 0
        var union = 0
        for index in pixels.indices {
            let lhs = pixels[index] != 0
            let rhs = other.pixels[index] != 0
            if lhs && rhs { intersection += 1 }
            if lhs || rhs { union += 1 }
        }
        guard union > 0 else { return 1 }
        return Double(intersection) / Double(union)
    }
}

nonisolated struct MangaLayout4V1MaskComponentSummary: Sendable, Equatable {
    let pixelCount: Int
    let prototypeBounds: CGRect
    let bboxRelativeArea: Double
}

nonisolated struct MangaLayout4V1BalloonInstance: Sendable, Equatable {
    let confidence: Float
    let boundingBox: CGRect
    let mask: MangaLayout4V1BinaryMask
    let contours: [MangaVisionContour]
    let componentSummaries: [MangaLayout4V1MaskComponentSummary]

    var primaryContour: MangaVisionContour? { contours.first }
    var secondaryContours: [MangaVisionContour] {
        contours.isEmpty ? [] : Array(contours.dropFirst())
    }
}

nonisolated enum MangaLayout4V1MaskDecoder {
    private struct Component {
        let indices: [Int]
        let bounds: CGRect
    }

    static func decodeBalloonInstances(
        detections: [MangaLayout4V1Detection],
        rawOutputs: [String: MLMultiArray],
        letterbox: MangaLayout4V1Letterbox,
        configuration: MangaLayout4V1Configuration = MangaLayout4V1Configuration()
    ) throws -> [MangaLayout4V1BalloonInstance] {
        guard let prototypeSpec = MangaLayout4V1OutputContract.spec(named: "mask_prototypes"),
              let prototypeArray = rawOutputs[prototypeSpec.name] else {
            throw MangaLayout4V1Error.missingOutput("mask_prototypes")
        }
        let prototypes = try MangaLayout4V1TensorReader(
            array: prototypeArray,
            name: prototypeSpec.name,
            expectedShape: [
                1,
                prototypeSpec.channels,
                prototypeSpec.height,
                prototypeSpec.width
            ]
        )

        return detections.compactMap { detection in
            guard detection.layoutClass == .balloon else { return nil }
            guard detection.maskCoefficients.count == MangaLayout4V1OutputContract.prototypeCount else {
                return nil
            }
            let mask = combineAndCrop(
                coefficients: detection.maskCoefficients,
                prototypes: prototypes,
                detectionBox: detection.modelRect,
                width: prototypeSpec.width,
                height: prototypeSpec.height,
                threshold: configuration.balloonMaskThreshold
            )
            let components = connectedComponents(mask)
                .sorted { lhs, rhs in
                    if lhs.indices.count != rhs.indices.count {
                        return lhs.indices.count > rhs.indices.count
                    }
                    if lhs.bounds.minY != rhs.bounds.minY {
                        return lhs.bounds.minY < rhs.bounds.minY
                    }
                    return lhs.bounds.minX < rhs.bounds.minX
                }

            let detectionPrototypeArea = max(
                detection.modelRect.width * CGFloat(prototypeSpec.width) / 640
                    * detection.modelRect.height * CGFloat(prototypeSpec.height) / 640,
                1
            )
            let summaries = components.map {
                MangaLayout4V1MaskComponentSummary(
                    pixelCount: $0.indices.count,
                    prototypeBounds: $0.bounds,
                    bboxRelativeArea: Double(CGFloat($0.indices.count) / detectionPrototypeArea)
                )
            }
            let contours = components.compactMap {
                contour(
                    for: $0,
                    in: mask,
                    letterbox: letterbox
                )
            }
            return MangaLayout4V1BalloonInstance(
                confidence: detection.confidence,
                boundingBox: detection.normalizedRect,
                mask: mask,
                contours: contours,
                componentSummaries: summaries
            )
        }
    }

    /// Python reference order:
    /// tanh(coeff) -> sum(coeff * prototype) -> sigmoid -> threshold -> bbox crop.
    static func combineAndCrop(
        coefficients rawCoefficients: [Float],
        prototypes: MangaLayout4V1TensorReader,
        detectionBox: CGRect,
        width: Int = 320,
        height: Int = 320,
        threshold: Float
    ) -> MangaLayout4V1BinaryMask {
        let coefficients = rawCoefficients.map { tanh($0) }
        let scaleX = CGFloat(width) / 640
        let scaleY = CGFloat(height) / 640
        let x1 = min(max(Int(floor(detectionBox.minX * scaleX)), 0), width)
        let y1 = min(max(Int(floor(detectionBox.minY * scaleY)), 0), height)
        let x2 = min(max(Int(ceil(detectionBox.maxX * scaleX)), 0), width)
        let y2 = min(max(Int(ceil(detectionBox.maxY * scaleY)), 0), height)
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard x2 > x1, y2 > y1 else {
            return MangaLayout4V1BinaryMask(width: width, height: height, pixels: pixels)
        }

        for y in y1..<y2 {
            for x in x1..<x2 {
                var logit: Float = 0
                for channel in 0..<min(coefficients.count, MangaLayout4V1OutputContract.prototypeCount) {
                    logit += coefficients[channel] * prototypes.value(channel: channel, y: y, x: x)
                }
                if MangaLayout4V1Decoder.sigmoid(logit) >= threshold {
                    pixels[y * width + x] = 1
                }
            }
        }
        return MangaLayout4V1BinaryMask(width: width, height: height, pixels: pixels)
    }

    /// Eight-connected components keep diagonally touching pixels in one instance contour.
    /// Every component is preserved; no largest-component-only shortcut is applied.
    private static func connectedComponents(
        _ mask: MangaLayout4V1BinaryMask
    ) -> [Component] {
        var visited = [Bool](repeating: false, count: mask.pixels.count)
        var result: [Component] = []
        let neighbors = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        for seed in mask.pixels.indices where mask.pixels[seed] != 0 && !visited[seed] {
            visited[seed] = true
            var queue = [seed]
            var cursor = 0
            var indices: [Int] = []
            var minX = mask.width
            var minY = mask.height
            var maxX = 0
            var maxY = 0

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                indices.append(index)
                let x = index % mask.width
                let y = index / mask.width
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                for (dx, dy) in neighbors {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < mask.width, ny >= 0, ny < mask.height else {
                        continue
                    }
                    let next = ny * mask.width + nx
                    guard mask.pixels[next] != 0, !visited[next] else { continue }
                    visited[next] = true
                    queue.append(next)
                }
            }

            result.append(
                Component(
                    indices: indices,
                    bounds: CGRect(
                        x: minX,
                        y: minY,
                        width: maxX - minX + 1,
                        height: maxY - minY + 1
                    )
                )
            )
        }
        return result
    }

    /// Produces a deterministic outer scanline contour for each connected component.
    /// This retains all disconnected components while avoiding a page-level mask union.
    /// A future contour-specific quality pass may replace the tracing policy without
    /// changing the stable reader domain.
    private static func contour(
        for component: Component,
        in mask: MangaLayout4V1BinaryMask,
        letterbox: MangaLayout4V1Letterbox
    ) -> MangaVisionContour? {
        guard !component.indices.isEmpty else { return nil }
        var rowExtents: [Int: (minX: Int, maxX: Int)] = [:]
        rowExtents.reserveCapacity(Int(component.bounds.height))
        for index in component.indices {
            let x = index % mask.width
            let y = index / mask.width
            if let existing = rowExtents[y] {
                rowExtents[y] = (min(existing.minX, x), max(existing.maxX, x))
            } else {
                rowExtents[y] = (x, x)
            }
        }
        let rows = rowExtents.keys.sorted()
        guard !rows.isEmpty else { return nil }

        var prototypePoints: [CGPoint] = []
        prototypePoints.reserveCapacity(rows.count * 2)
        for y in rows {
            if let extent = rowExtents[y] {
                prototypePoints.append(
                    CGPoint(x: CGFloat(extent.minX) + 0.5, y: CGFloat(y) + 0.5)
                )
            }
        }
        for y in rows.reversed() {
            if let extent = rowExtents[y] {
                prototypePoints.append(
                    CGPoint(x: CGFloat(extent.maxX) + 0.5, y: CGFloat(y) + 0.5)
                )
            }
        }

        let modelScaleX = CGFloat(640) / CGFloat(mask.width)
        let modelScaleY = CGFloat(640) / CGFloat(mask.height)
        var normalized = prototypePoints.map { point in
            letterbox.sourceNormalizedPoint(
                fromModelPoint: CGPoint(
                    x: point.x * modelScaleX,
                    y: point.y * modelScaleY
                )
            )
        }
        normalized = removeConsecutiveDuplicates(normalized)
        guard normalized.count >= 3 else { return nil }
        return MangaVisionContour(points: normalized)
    }

    private static func removeConsecutiveDuplicates(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last,
               abs(last.x - point.x) < 0.000_001,
               abs(last.y - point.y) < 0.000_001 {
                continue
            }
            result.append(point)
        }
        if result.count > 1,
           let first = result.first,
           let last = result.last,
           abs(first.x - last.x) < 0.000_001,
           abs(first.y - last.y) < 0.000_001 {
            result.removeLast()
        }
        return result
    }
}
