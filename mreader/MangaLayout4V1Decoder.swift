import CoreGraphics
import CoreML
import Foundation

nonisolated struct MangaLayout4V1Detection: Sendable, Equatable {
    let layoutClass: MangaLayout4V1Class
    let confidence: Float
    /// 640x640 letterboxed model-input coordinates, top-left origin.
    let modelRect: CGRect
    /// Original-page coordinates normalized to 0...1, top-left origin.
    let normalizedRect: CGRect
    let pyramidLevel: String
    /// Eight raw per-location coefficients. They remain adapter-internal and are
    /// consumed only when producing balloon instance masks.
    let maskCoefficients: [Float]
}

nonisolated struct MangaLayout4V1DecodeDiagnostics: Sendable, Equatable {
    let totalLocationClassCount: Int
    let preThresholdTopKCount: Int
    let postThresholdCounts: [MangaLayout4V1Class: Int]
    let postNMSCounts: [MangaLayout4V1Class: Int]
    let maximumScores: [MangaLayout4V1Class: Float]
}

nonisolated struct MangaLayout4V1DecodeResult: Sendable, Equatable {
    let detections: [MangaLayout4V1Detection]
    let diagnostics: MangaLayout4V1DecodeDiagnostics
}

nonisolated struct MangaLayout4V1TensorReader {
    private let storage: MLMultiArray
    private let pointer: UnsafeRawPointer
    private let strides: [Int]

    init(array: MLMultiArray, name: String, expectedShape: [Int]) throws {
        let actualShape = array.shape.map(\.intValue)
        guard actualShape == expectedShape else {
            throw MangaLayout4V1Error.outputShape(
                name: name,
                actual: actualShape,
                expected: expectedShape
            )
        }
        guard array.dataType == .float32 else {
            throw MangaLayout4V1Error.unsupportedDataType(
                name: name,
                actual: String(describing: array.dataType)
            )
        }
        let actualStrides = array.strides.map(\.intValue)
        guard actualStrides.count == expectedShape.count,
              actualStrides.allSatisfy({ $0 >= 0 }) else {
            throw MangaLayout4V1Error.invalidInput(
                "invalid strides for \(name): \(actualStrides)"
            )
        }
        storage = array
        pointer = UnsafeRawPointer(array.dataPointer)
        strides = actualStrides
    }

    @inline(__always)
    func value(channel: Int, y: Int, x: Int) -> Float {
        let offset = channel * strides[1] + y * strides[2] + x * strides[3]
        return pointer.load(
            fromByteOffset: offset * MemoryLayout<Float32>.stride,
            as: Float32.self
        )
    }
}

nonisolated enum MangaLayout4V1Decoder {
    private struct RankedScore: Sendable, Equatable {
        let score: Float
        let flatIndex: Int
    }

    private struct Candidate: Sendable, Equatable {
        let layoutClass: MangaLayout4V1Class
        let score: Float
        let modelRect: CGRect
        let pyramidLevel: String
        let maskCoefficients: [Float]
        let stableOrder: Int
    }

    static func decode(
        rawOutputs: [String: MLMultiArray],
        letterbox: MangaLayout4V1Letterbox,
        configuration: MangaLayout4V1Configuration = MangaLayout4V1Configuration()
    ) throws -> MangaLayout4V1DecodeResult {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(configuration.preNMSTopKPerLevel * 4)

        var totalLocationClassCount = 0
        var preThresholdTopKCount = 0
        var postThresholdCounts: [MangaLayout4V1Class: Int] = [:]
        var maximumScores: [MangaLayout4V1Class: Float] = [:]
        var stableOrder = 0

        for level in ["p2", "p3", "p4", "p5"] {
            guard let clsSpec = MangaLayout4V1OutputContract.spec(
                level: level,
                role: "classification"
            ),
            let bboxSpec = MangaLayout4V1OutputContract.spec(
                level: level,
                role: "bbox"
            ),
            let coeffSpec = MangaLayout4V1OutputContract.spec(
                level: level,
                role: "mask_coeff"
            ),
            let clsArray = rawOutputs[clsSpec.name],
            let bboxArray = rawOutputs[bboxSpec.name],
            let coeffArray = rawOutputs[coeffSpec.name] else {
                throw MangaLayout4V1Error.missingOutput(level)
            }

            let cls = try MangaLayout4V1TensorReader(
                array: clsArray,
                name: clsSpec.name,
                expectedShape: [1, clsSpec.channels, clsSpec.height, clsSpec.width]
            )
            let bbox = try MangaLayout4V1TensorReader(
                array: bboxArray,
                name: bboxSpec.name,
                expectedShape: [1, bboxSpec.channels, bboxSpec.height, bboxSpec.width]
            )
            let coeff = try MangaLayout4V1TensorReader(
                array: coeffArray,
                name: coeffSpec.name,
                expectedShape: [1, coeffSpec.channels, coeffSpec.height, coeffSpec.width]
            )

            let levelCount = clsSpec.height * clsSpec.width * MangaLayout4V1OutputContract.classCount
            totalLocationClassCount += levelCount
            let topK = topKScores(
                reader: cls,
                height: clsSpec.height,
                width: clsSpec.width,
                count: min(configuration.preNMSTopKPerLevel, levelCount)
            )
            preThresholdTopKCount += topK.count

            for ranked in topK {
                let pointIndex = ranked.flatIndex / MangaLayout4V1OutputContract.classCount
                let classID = ranked.flatIndex % MangaLayout4V1OutputContract.classCount
                guard let layoutClass = MangaLayout4V1Class(rawValue: classID) else {
                    continue
                }
                maximumScores[layoutClass] = max(
                    maximumScores[layoutClass] ?? 0,
                    ranked.score
                )
                guard ranked.score >= configuration.scoreThreshold(for: layoutClass) else {
                    continue
                }

                let y = pointIndex / clsSpec.width
                let x = pointIndex % clsSpec.width
                let center = featureCenter(x: x, y: y, stride: clsSpec.stride)
                let left = softplus(bbox.value(channel: 0, y: y, x: x))
                    * Float(clsSpec.stride)
                let top = softplus(bbox.value(channel: 1, y: y, x: x))
                    * Float(clsSpec.stride)
                let right = softplus(bbox.value(channel: 2, y: y, x: x))
                    * Float(clsSpec.stride)
                let bottom = softplus(bbox.value(channel: 3, y: y, x: x))
                    * Float(clsSpec.stride)

                let x1 = max(center.x - left, 0)
                let y1 = max(center.y - top, 0)
                let x2 = min(center.x + right, 640)
                let y2 = min(center.y + bottom, 640)
                guard x2 > x1, y2 > y1 else { continue }

                var coefficients: [Float] = []
                coefficients.reserveCapacity(MangaLayout4V1OutputContract.prototypeCount)
                for channel in 0..<MangaLayout4V1OutputContract.prototypeCount {
                    coefficients.append(coeff.value(channel: channel, y: y, x: x))
                }

                candidates.append(
                    Candidate(
                        layoutClass: layoutClass,
                        score: ranked.score,
                        modelRect: CGRect(
                            x: CGFloat(x1),
                            y: CGFloat(y1),
                            width: CGFloat(x2 - x1),
                            height: CGFloat(y2 - y1)
                        ),
                        pyramidLevel: level,
                        maskCoefficients: coefficients,
                        stableOrder: stableOrder
                    )
                )
                stableOrder += 1
                postThresholdCounts[layoutClass, default: 0] += 1
            }
        }

        var kept: [Candidate] = []
        var postNMSCounts: [MangaLayout4V1Class: Int] = [:]
        for layoutClass in MangaLayout4V1Class.allCases {
            let classCandidates = candidates
                .filter { $0.layoutClass == layoutClass }
                .sorted(by: preferred)
            let classKept = classAwareNMS(
                classCandidates,
                threshold: configuration.nmsThreshold(for: layoutClass)
            )
            postNMSCounts[layoutClass] = classKept.count
            kept.append(contentsOf: classKept)
        }

        let final = kept
            .sorted(by: preferred)
            .prefix(max(configuration.maxDetections, 0))
            .map { candidate in
                MangaLayout4V1Detection(
                    layoutClass: candidate.layoutClass,
                    confidence: candidate.score,
                    modelRect: candidate.modelRect,
                    normalizedRect: letterbox.sourceNormalizedRect(
                        fromModelRect: candidate.modelRect
                    ),
                    pyramidLevel: candidate.pyramidLevel,
                    maskCoefficients: candidate.maskCoefficients
                )
            }

        return MangaLayout4V1DecodeResult(
            detections: Array(final),
            diagnostics: MangaLayout4V1DecodeDiagnostics(
                totalLocationClassCount: totalLocationClassCount,
                preThresholdTopKCount: preThresholdTopKCount,
                postThresholdCounts: postThresholdCounts,
                postNMSCounts: postNMSCounts,
                maximumScores: maximumScores
            )
        )
    }

    /// PyTorch reference:
    /// (arange + 0.5) * stride.
    static func featureCenter(x: Int, y: Int, stride: Int) -> (x: Float, y: Float) {
        (
            (Float(x) + 0.5) * Float(stride),
            (Float(y) + 0.5) * Float(stride)
        )
    }

    /// Stable sigmoid used by classification logits and mask logits.
    @inline(__always)
    static func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            return 1 / (1 + exp(-value))
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }

    /// Matches torch.nn.functional.softplus(raw) with beta=1, threshold=20.
    @inline(__always)
    static func softplus(_ value: Float) -> Float {
        if value > 20 { return value }
        if value < -20 { return exp(value) }
        return log1p(exp(value))
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = max(intersection.width, 0) * max(intersection.height, 0)
        let lhsArea = max(lhs.width, 0) * max(lhs.height, 0)
        let rhsArea = max(rhs.width, 0) * max(rhs.height, 0)
        let union = lhsArea + rhsArea - intersectionArea
        guard union > 0 else { return 0 }
        return intersectionArea / union
    }

    private static func topKScores(
        reader: MangaLayout4V1TensorReader,
        height: Int,
        width: Int,
        count: Int
    ) -> [RankedScore] {
        guard count > 0 else { return [] }
        var heap: [RankedScore] = []
        heap.reserveCapacity(count)

        for y in 0..<height {
            for x in 0..<width {
                let pointIndex = y * width + x
                for classID in 0..<MangaLayout4V1OutputContract.classCount {
                    let score = sigmoid(reader.value(channel: classID, y: y, x: x))
                    let item = RankedScore(
                        score: score,
                        flatIndex: pointIndex * MangaLayout4V1OutputContract.classCount + classID
                    )
                    if heap.count < count {
                        heap.append(item)
                        siftUpMinHeap(&heap, from: heap.count - 1)
                    } else if rankedScorePreferred(item, over: heap[0]) {
                        heap[0] = item
                        siftDownMinHeap(&heap, from: 0)
                    }
                }
            }
        }

        return heap.sorted { rankedScorePreferred($0, over: $1) }
    }

    /// For deterministic fixtures, equal scores use the smaller PyTorch-style flat
    /// index first. Real trained logits almost never tie exactly.
    private static func rankedScorePreferred(_ lhs: RankedScore, over rhs: RankedScore) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.flatIndex < rhs.flatIndex
    }

    /// Min-heap ordering: the least desirable retained value stays at root.
    private static func minHeapPrecedes(_ lhs: RankedScore, _ rhs: RankedScore) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return lhs.flatIndex > rhs.flatIndex
    }

    private static func siftUpMinHeap(_ heap: inout [RankedScore], from start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard minHeapPrecedes(heap[index], heap[parent]) else { break }
            heap.swapAt(index, parent)
            index = parent
        }
    }

    private static func siftDownMinHeap(_ heap: inout [RankedScore], from start: Int) {
        var index = start
        while true {
            let left = index * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var child = left
            if right < heap.count, minHeapPrecedes(heap[right], heap[left]) {
                child = right
            }
            guard minHeapPrecedes(heap[child], heap[index]) else { return }
            heap.swapAt(index, child)
            index = child
        }
    }

    private static func classAwareNMS(
        _ candidates: [Candidate],
        threshold: Float
    ) -> [Candidate] {
        var kept: [Candidate] = []
        kept.reserveCapacity(candidates.count)
        for candidate in candidates {
            let suppressed = kept.contains { existing in
                intersectionOverUnion(candidate.modelRect, existing.modelRect)
                    > CGFloat(threshold)
            }
            if !suppressed {
                kept.append(candidate)
            }
        }
        return kept
    }

    private static func preferred(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.layoutClass.rawValue != rhs.layoutClass.rawValue {
            return lhs.layoutClass.rawValue < rhs.layoutClass.rawValue
        }
        return lhs.stableOrder < rhs.stableOrder
    }
}
