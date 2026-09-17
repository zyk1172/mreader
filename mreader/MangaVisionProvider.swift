import CoreML
import Foundation
@preconcurrency import Vision
import os

nonisolated struct MangaVisionProviderDescriptor: Sendable, Equatable {
    let modelIdentifier: String
    let modelVersion: Int
    let inputSize: CGSize
    let supportedRegionTypes: Set<MangaRegionType>
}

nonisolated protocol MangaVisionProvider: Sendable {
    var descriptor: MangaVisionProviderDescriptor { get async }
    func analyzePage(
        image: CGImage,
        sourceImageSize: CGSize,
        pageIdentifier: MangaPageIdentifier
    ) async throws -> MangaPageAnalysis
}

nonisolated enum MangaVisionProviderError: Error, Sendable {
    case modelUnavailable
    case unsupportedOutput
}

/// Adapter for the bundled Ultralytics segmentation export. Class IDs, tensor
/// layouts, model-input coordinates and mask decoding all stop at this boundary.
actor YOLOMangaVisionProvider: MangaVisionProvider {
    static let shared = YOLOMangaVisionProvider()

    private struct Runtime {
        let model: MLModel
        let visionModel: VNCoreMLModel
        let labelsByClassID: [Int: String]
        let descriptor: MangaVisionProviderDescriptor
    }

    private struct DecodedCandidate {
        let region: MangaVisionRegion
        let instanceIndex: Int
        let modelRect: CGRect
        let maskCoefficients: [Double]
    }

    private enum SegmentationTensorLayout {
        case direct(
            array: MLMultiArray,
            instanceAxis: Int,
            yAxis: Int,
            xAxis: Int,
            instanceCount: Int,
            height: Int,
            width: Int,
            usesLogits: Bool
        )
        case prototypes(
            array: MLMultiArray,
            channelAxis: Int,
            yAxis: Int,
            xAxis: Int,
            channelCount: Int,
            height: Int,
            width: Int
        )
    }

    private let modelResourceName: String
    private var runtime: Runtime?
    private var measuredColdLoadMilliseconds: Double?

    init(modelResourceName: String = "PanelDetector") {
        self.modelResourceName = modelResourceName
    }

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
        let runtime = try loadRuntime()
        let request = VNCoreMLRequest(model: runtime.visionModel)
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let featureArrays = (request.results ?? [])
            .compactMap { $0 as? VNCoreMLFeatureValueObservation }
            .compactMap { $0.featureValue.multiArrayValue }
        guard let detectionIndex = MangaVisionOutputContract.firstDetectionTensorIndex(in: featureArrays) else {
            MReaderLog.aiVision.error(
                "MangaVision output contract failed at runtime revision=\(MangaVisionOutputContract.revision, privacy: .public) reason=missing-compatible-detection-output"
            )
            throw MangaVisionProviderError.unsupportedOutput
        }
        let detectionOutput = featureArrays[detectionIndex]
        let segmentationOutputs = featureArrays.enumerated().compactMap { index, array in
            index == detectionIndex ? nil : array
        }

        let profile = MangaVisionCalibrationProfile.bundled
        let decoded = Self.decodeRegions(
            detectionOutput,
            segmentationOutputs: segmentationOutputs,
            analysisImageSize: CGSize(width: image.width, height: image.height),
            labelsByClassID: runtime.labelsByClassID,
            inputSize: runtime.descriptor.inputSize,
            thresholds: profile.confidenceThresholds
        )
        let grouped = Dictionary(grouping: decoded, by: \.type)
        return MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: grouped[.panel] ?? [],
            texts: profile.deduplicated(grouped[.text] ?? [], type: .text),
            balloons: profile.deduplicated(grouped[.balloon] ?? [], type: .balloon),
            faces: profile.deduplicated(grouped[.face] ?? [], type: .face),
            bodies: profile.deduplicated(grouped[.body] ?? [], type: .body),
            modelIdentifier: runtime.descriptor.modelIdentifier,
            modelVersion: runtime.descriptor.modelVersion
        )
    }

    func coldLoadMillisecondsForDiagnostics() -> Double? {
        measuredColdLoadMilliseconds
    }

    private func loadRuntime() throws -> Runtime {
        if let runtime { return runtime }
        let start = ContinuousClock.now
        guard let modelURL = Bundle.main.url(forResource: modelResourceName, withExtension: "mlmodelc") else {
            throw MangaVisionProviderError.modelUnavailable
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let metadataLabels = Self.classLabels(from: model.modelDescription.metadata)
        // The fallback is a checked manifest for the exact bundled checkpoint,
        // used only when the Core ML export omits/loses creator-defined `names`.
        let labels = metadataLabels.isEmpty ? Self.bundledCheckpointLabels : metadataLabels
        let supported = Set(labels.values.compactMap(Self.semanticRegionType(forLabel:)))
        let contractViolations = MangaVisionOutputContract.validate(
            modelDescription: model.modelDescription,
            supportedRegionTypes: supported
        )
        guard contractViolations.isEmpty else {
            MReaderLog.aiVision.error(
                "MangaVision bundled model rejected contract=\(MangaVisionOutputContract.revision, privacy: .public) violations=\(contractViolations.joined(separator: ","), privacy: .public)"
            )
            throw MangaVisionProviderError.unsupportedOutput
        }
        let visionModel = try VNCoreMLModel(for: model)
        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: "manga109-yolo26s-seg-coreml-fp16-640-v2-manga-vision",
            // v4 consumes frame/text/balloon together and decodes instance-mask
            // outputs when the bundled Core ML export exposes them.
            modelVersion: 4,
            inputSize: MangaVisionOutputContract.expectedInputSize,
            supportedRegionTypes: supported
        )
        let loaded = Runtime(
            model: model,
            visionModel: visionModel,
            labelsByClassID: labels,
            descriptor: descriptor
        )
        runtime = loaded
        measuredColdLoadMilliseconds = Self.milliseconds(start.duration(to: .now))
        return loaded
    }

    // Verified against the exact checkpoint documented in GUIDED_PANEL_MODEL.md.
    // It is intentionally private to this adapter; business code never sees IDs.
    private static let bundledCheckpointLabels: [Int: String] = [
        0: "frame",
        1: "text",
        2: "balloon"
    ]

    private static let fallbackDescriptor = MangaVisionProviderDescriptor(
        modelIdentifier: "manga109-yolo26s-seg-coreml-fp16-640-v2-manga-vision",
        modelVersion: 4,
        inputSize: MangaVisionOutputContract.expectedInputSize,
        supportedRegionTypes: MangaVisionOutputContract.requiredSemanticClasses
    )

    private static func classLabels(from metadata: [MLModelMetadataKey: Any]) -> [Int: String] {
        guard let creatorValue = metadata[.creatorDefinedKey] else { return [:] }
        let creator: [String: Any]
        if let value = creatorValue as? [String: Any] {
            creator = value
        } else if let value = creatorValue as? [String: String] {
            creator = value
        } else if let value = creatorValue as? NSDictionary {
            var converted: [String: Any] = [:]
            for (key, value) in value {
                if let key = key as? String { converted[key] = value }
            }
            creator = converted
        } else {
            return [:]
        }
        guard let rawNames = creator["names"] else { return [:] }
        if let dictionary = rawNames as? [String: String] {
            return Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
        }
        if let dictionary = rawNames as? [Int: String] {
            return dictionary
        }
        return parseClassLabels(String(describing: rawNames))
    }

    /// Ultralytics commonly stores `names` as a Python-dict-looking string in
    /// creator metadata rather than JSON. Parse both quoted label styles.
    static func parseClassLabelsForDiagnostics(_ raw: String) -> [Int: String] {
        parseClassLabels(raw)
    }

    private static func parseClassLabels(_ raw: String) -> [Int: String] {
        let pattern = #"(\d+)\s*:\s*['\"]([^'\"]+)['\"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var result: [Int: String] = [:]
        for match in regex.matches(in: raw, range: nsRange) {
            guard let idRange = Range(match.range(at: 1), in: raw),
                  let labelRange = Range(match.range(at: 2), in: raw),
                  let id = Int(raw[idRange]) else { continue }
            result[id] = String(raw[labelRange])
        }
        return result
    }

    private static func semanticRegionType(forLabel label: String) -> MangaRegionType? {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "frame", "panel", "comic_panel": return .panel
        case "text", "text_region", "textbox", "text_box": return .text
        case "balloon", "bubble", "speech_balloon", "speech_bubble": return .balloon
        case "face", "head": return .face
        case "body", "person_body", "character_body": return .body
        default: return nil
        }
    }

    static func decodeForDiagnostics(
        _ output: MLMultiArray,
        segmentationOutput: MLMultiArray? = nil,
        analysisImageSize: CGSize,
        labelsByClassID: [Int: String],
        inputSize: CGSize = MangaVisionOutputContract.expectedInputSize,
        thresholds: [MangaRegionType: Float]? = nil
    ) -> [MangaVisionRegion] {
        decodeRegions(
            output,
            segmentationOutputs: segmentationOutput.map { [$0] } ?? [],
            analysisImageSize: analysisImageSize,
            labelsByClassID: labelsByClassID,
            inputSize: inputSize,
            thresholds: thresholds ?? MangaVisionCalibrationProfile.bundled.confidenceThresholds
        )
    }

    private static func decodeRegions(
        _ output: MLMultiArray,
        segmentationOutputs: [MLMultiArray],
        analysisImageSize: CGSize,
        labelsByClassID: [Int: String],
        inputSize: CGSize,
        thresholds: [MangaRegionType: Float]
    ) -> [MangaVisionRegion] {
        guard let tensorLayout = MangaVisionOutputContract.detectionTensorLayout(for: output),
              analysisImageSize.width > 0,
              analysisImageSize.height > 0 else { return [] }

        func value(instance: Int, feature: Int) -> Double {
            let indices: [NSNumber] = tensorLayout.rowMajor
                ? [0, NSNumber(value: instance), NSNumber(value: feature)]
                : [0, NSNumber(value: feature), NSNumber(value: instance)]
            return output[indices].doubleValue
        }

        var candidates: [DecodedCandidate] = []
        candidates.reserveCapacity(min(tensorLayout.instanceCount, 96))
        for index in 0..<tensorLayout.instanceCount {
            let confidence = Float(value(instance: index, feature: 4))
            guard confidence.isFinite else { continue }
            let classID = Int(value(instance: index, feature: 5).rounded())
            guard let label = labelsByClassID[classID],
                  let type = semanticRegionType(forLabel: label),
                  confidence >= (thresholds[type] ?? 0.20) else { continue }

            var x1 = CGFloat(value(instance: index, feature: 0))
            var y1 = CGFloat(value(instance: index, feature: 1))
            var x2 = CGFloat(value(instance: index, feature: 2))
            var y2 = CGFloat(value(instance: index, feature: 3))
            guard x1.isFinite, y1.isFinite, x2.isFinite, y2.isFinite else { continue }
            let maximumCoordinate = max(abs(x1), abs(y1), abs(x2), abs(y2))
            if maximumCoordinate <= 2 {
                x1 *= inputSize.width
                x2 *= inputSize.width
                y1 *= inputSize.height
                y2 *= inputSize.height
            }
            let modelRect = CGRect(
                x: min(x1, x2),
                y: min(y1, y2),
                width: abs(x2 - x1),
                height: abs(y2 - y1)
            )
            let rect = MangaPageCoordinateSpace.sourceNormalizedRectFromScaleFitXYXY(
                x1: modelRect.minX,
                y1: modelRect.minY,
                x2: modelRect.maxX,
                y2: modelRect.maxY,
                inputSize: inputSize,
                sourceSize: analysisImageSize
            )
            guard rect.width > 0.002, rect.height > 0.002 else { continue }
            let coefficients: [Double]
            if tensorLayout.featureCount > 6 {
                coefficients = (6..<tensorLayout.featureCount).map {
                    value(instance: index, feature: $0)
                }
            } else {
                coefficients = []
            }
            candidates.append(DecodedCandidate(
                region: MangaVisionRegion(
                    type: type,
                    normalizedRect: rect,
                    confidence: confidence
                ),
                instanceIndex: index,
                modelRect: modelRect,
                maskCoefficients: coefficients
            ))
        }

        guard !segmentationOutputs.isEmpty else {
            return candidates.map(\.region)
        }
        let segmentationLayouts = segmentationOutputs.compactMap {
            segmentationTensorLayout(
                $0,
                instanceCount: tensorLayout.instanceCount,
                coefficientCount: max(tensorLayout.featureCount - 6, 0)
            )
        }
        guard !segmentationLayouts.isEmpty else {
            return candidates.map(\.region)
        }

        return candidates.map { candidate in
            // Exact contours materially help panel gutters and balloon geometry.
            // Text masks are intentionally left box-only: decoding dozens of glyph
            // regions would add CPU work without improving the OCR ROI contract.
            guard candidate.region.type == .panel || candidate.region.type == .balloon,
                  let contour = segmentationLayouts.lazy.compactMap({ layout in
                      maskContour(
                          for: candidate,
                          layout: layout,
                          inputSize: inputSize,
                          sourceSize: analysisImageSize
                      )
                  }).first else {
                return candidate.region
            }
            return MangaVisionRegion(
                id: candidate.region.id,
                type: candidate.region.type,
                normalizedRect: candidate.region.normalizedRect,
                confidence: candidate.region.confidence,
                contour: contour
            )
        }
    }

    private static func segmentationTensorLayout(
        _ array: MLMultiArray,
        instanceCount: Int,
        coefficientCount: Int
    ) -> SegmentationTensorLayout? {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1 else { return nil }

        let candidateAxes = [1, 2, 3]
        if let instanceAxis = candidateAxes.first(where: { axis in
            shape[axis] == instanceCount
                && candidateAxes.filter { $0 != axis }.allSatisfy { shape[$0] >= 4 }
        }) {
            let spatial = candidateAxes.filter { $0 != instanceAxis }
            let yAxis = spatial[0]
            let xAxis = spatial[1]
            let usesLogits = directMaskUsesLogits(
                array,
                instanceAxis: instanceAxis,
                yAxis: yAxis,
                xAxis: xAxis,
                height: shape[yAxis],
                width: shape[xAxis]
            )
            return .direct(
                array: array,
                instanceAxis: instanceAxis,
                yAxis: yAxis,
                xAxis: xAxis,
                instanceCount: instanceCount,
                height: shape[yAxis],
                width: shape[xAxis],
                usesLogits: usesLogits
            )
        }

        guard coefficientCount > 0,
              let channelAxis = candidateAxes.first(where: { shape[$0] == coefficientCount }) else {
            return nil
        }
        let spatial = candidateAxes.filter { $0 != channelAxis }
        guard spatial.count == 2,
              shape[spatial[0]] >= 4,
              shape[spatial[1]] >= 4 else { return nil }
        return .prototypes(
            array: array,
            channelAxis: channelAxis,
            yAxis: spatial[0],
            xAxis: spatial[1],
            channelCount: coefficientCount,
            height: shape[spatial[0]],
            width: shape[spatial[1]]
        )
    }

    private static func directMaskUsesLogits(
        _ array: MLMultiArray,
        instanceAxis: Int,
        yAxis: Int,
        xAxis: Int,
        height: Int,
        width: Int
    ) -> Bool {
        let sampleRows = [0, height / 4, height / 2, max(height - 1, 0)]
        let sampleColumns = [0, width / 4, width / 2, max(width - 1, 0)]
        for y in sampleRows where y < height {
            for x in sampleColumns where x < width {
                let value = arrayValue4D(
                    array,
                    axisValues: [instanceAxis: 0, yAxis: y, xAxis: x]
                )
                if value < -0.001 || value > 1.001 { return true }
            }
        }
        return false
    }

    private static func maskContour(
        for candidate: DecodedCandidate,
        layout: SegmentationTensorLayout,
        inputSize: CGSize,
        sourceSize: CGSize
    ) -> MangaVisionContour? {
        let width: Int
        let height: Int
        let isActive: (Int, Int) -> Bool

        switch layout {
        case let .direct(array, instanceAxis, yAxis, xAxis, instanceCount, h, w, usesLogits):
            guard candidate.instanceIndex < instanceCount else { return nil }
            width = w
            height = h
            isActive = { x, y in
                let value = arrayValue4D(
                    array,
                    axisValues: [
                        instanceAxis: candidate.instanceIndex,
                        yAxis: y,
                        xAxis: x
                    ]
                )
                return usesLogits ? value > 0 : value >= 0.5
            }

        case let .prototypes(array, channelAxis, yAxis, xAxis, channelCount, h, w):
            guard candidate.maskCoefficients.count >= channelCount else { return nil }
            width = w
            height = h
            isActive = { x, y in
                var score = 0.0
                for channel in 0..<channelCount {
                    score += candidate.maskCoefficients[channel] * arrayValue4D(
                        array,
                        axisValues: [channelAxis: channel, yAxis: y, xAxis: x]
                    )
                }
                // sigmoid(score) > 0.5 iff score > 0.
                return score > 0
            }
        }

        guard width >= 4, height >= 4 else { return nil }
        let stepX = max(1, width / 80)
        let stepY = max(1, height / 80)
        let cellWidth = inputSize.width / CGFloat(width)
        let cellHeight = inputSize.height / CGFloat(height)
        let cropRect = candidate.modelRect.insetBy(
            dx: -cellWidth * 1.5,
            dy: -cellHeight * 1.5
        )
        var pagePoints: [CGPoint] = []
        pagePoints.reserveCapacity(320)

        for y in Swift.stride(from: 0, to: height, by: stepY) {
            for x in Swift.stride(from: 0, to: width, by: stepX) {
                guard isActive(x, y) else { continue }
                let modelPoint = CGPoint(
                    x: (CGFloat(x) + 0.5) * cellWidth,
                    y: (CGFloat(y) + 0.5) * cellHeight
                )
                guard cropRect.contains(modelPoint),
                      let pagePoint = MangaPageCoordinateSpace.sourceNormalizedPointFromScaleFitModelPoint(
                          modelPoint,
                          inputSize: inputSize,
                          sourceSize: sourceSize
                      ) else { continue }
                pagePoints.append(pagePoint)
            }
        }

        guard pagePoints.count >= 3 else { return nil }
        let hull = convexHull(pagePoints)
        guard hull.count >= 3 else { return nil }
        return MangaVisionContour(points: hull)
    }

    private static func arrayValue4D(
        _ array: MLMultiArray,
        axisValues: [Int: Int]
    ) -> Double {
        var indices = [0, 0, 0, 0]
        for (axis, value) in axisValues where indices.indices.contains(axis) {
            indices[axis] = value
        }
        return array[indices.map { NSNumber(value: $0) }].doubleValue
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted {
            if abs($0.x - $1.x) > 0.000_001 { return $0.x < $1.x }
            return $0.y < $1.y
        }
        guard sorted.count > 2 else { return sorted }

        func cross(_ origin: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - origin.x) * (b.y - origin.y)
                - (a.y - origin.y) * (b.x - origin.x)
        }

        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

nonisolated enum MangaVisionRegionPostProcessor {
    static func deduplicated(
        _ regions: [MangaVisionRegion],
        iouThreshold: CGFloat = 0.62,
        containmentThreshold: CGFloat = 0.92
    ) -> [MangaVisionRegion] {
        var kept: [MangaVisionRegion] = []
        for candidate in regions.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { existing in
                guard existing.type == candidate.type else { return false }
                return MangaPageCoordinateSpace.intersectionOverUnion(
                    existing.normalizedRect,
                    candidate.normalizedRect
                ) >= iouThreshold
                    || MangaPageCoordinateSpace.containment(
                        of: candidate.normalizedRect,
                        in: existing.normalizedRect
                    ) >= containmentThreshold
                    || MangaPageCoordinateSpace.containment(
                        of: existing.normalizedRect,
                        in: candidate.normalizedRect
                    ) >= containmentThreshold
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }
}
