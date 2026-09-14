import CoreML
import Foundation
@preconcurrency import Vision

nonisolated struct MangaVisionProviderDescriptor: Sendable, Equatable {
    let modelIdentifier: String
    let modelVersion: Int
    let inputSize: CGSize
    let supportedRegionTypes: Set<MangaRegionType>
}

protocol MangaVisionProvider: Sendable {
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

/// Adapter for the currently bundled Ultralytics export. All class IDs, tensor
/// shape handling, input-size knowledge and Core ML/Vision details stop here.
/// A future self-trained provider only needs to satisfy `MangaVisionProvider`.
actor YOLOMangaVisionProvider: MangaVisionProvider {
    static let shared = YOLOMangaVisionProvider()

    private struct Runtime {
        let model: MLModel
        let visionModel: VNCoreMLModel
        let labelsByClassID: [Int: String]
        let descriptor: MangaVisionProviderDescriptor
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

        let featureObservations = (request.results ?? []).compactMap {
            $0 as? VNCoreMLFeatureValueObservation
        }
        guard let output = featureObservations
            .compactMap({ $0.featureValue.multiArrayValue })
            .first(where: Self.looksLikeDetectionTensor) else {
            throw MangaVisionProviderError.unsupportedOutput
        }

        let decoded = Self.decodeRegions(
            output,
            analysisImageSize: CGSize(width: image.width, height: image.height),
            labelsByClassID: runtime.labelsByClassID,
            inputSize: runtime.descriptor.inputSize,
            thresholds: Self.defaultConfidenceThresholds
        )
        let grouped = Dictionary(grouping: decoded, by: \.type)
        return MangaPageAnalysis(
            pageIdentifier: pageIdentifier,
            imageSize: sourceImageSize,
            panels: grouped[.panel] ?? [],
            texts: MangaVisionRegionPostProcessor.deduplicated(grouped[.text] ?? []),
            faces: MangaVisionRegionPostProcessor.deduplicated(grouped[.face] ?? []),
            bodies: MangaVisionRegionPostProcessor.deduplicated(grouped[.body] ?? []),
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
        let visionModel = try VNCoreMLModel(for: model)
        let metadataLabels = Self.classLabels(from: model.modelDescription.metadata)
        // The fallback is a checked manifest for the exact bundled checkpoint,
        // used only when the Core ML export omits/loses creator-defined `names`.
        let labels = metadataLabels.isEmpty ? Self.bundledCheckpointLabels : metadataLabels
        let supported = Set(labels.values.compactMap(Self.semanticRegionType(forLabel:)))
        let descriptor = MangaVisionProviderDescriptor(
            modelIdentifier: "manga109-yolo26s-seg-coreml-fp16-640-v2-manga-vision",
            modelVersion: 2,
            inputSize: CGSize(width: 640, height: 640),
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
        modelVersion: 2,
        inputSize: CGSize(width: 640, height: 640),
        supportedRegionTypes: [.panel, .text]
    )

    private static let defaultConfidenceThresholds: [MangaRegionType: Float] = [
        .panel: 0.24,
        .text: 0.18,
        .face: 0.20,
        .body: 0.20
    ]

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
        case "face", "head": return .face
        case "body", "person_body", "character_body": return .body
        default: return nil
        }
    }

    private static func looksLikeDetectionTensor(_ output: MLMultiArray) -> Bool {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 3, shape.first == 1 else { return false }
        let dimensions = Array(shape.dropFirst())
        return dimensions.contains(where: { $0 >= 6 && $0 <= 256 })
            && dimensions.contains(where: { $0 >= 1 && $0 <= 2_000 })
    }

    static func decodeForDiagnostics(
        _ output: MLMultiArray,
        analysisImageSize: CGSize,
        labelsByClassID: [Int: String],
        inputSize: CGSize = CGSize(width: 640, height: 640),
        thresholds: [MangaRegionType: Float]? = nil
    ) -> [MangaVisionRegion] {
        decodeRegions(
            output,
            analysisImageSize: analysisImageSize,
            labelsByClassID: labelsByClassID,
            inputSize: inputSize,
            thresholds: thresholds ?? defaultConfidenceThresholds
        )
    }

    private static func decodeRegions(
        _ output: MLMultiArray,
        analysisImageSize: CGSize,
        labelsByClassID: [Int: String],
        inputSize: CGSize,
        thresholds: [MangaRegionType: Float]
    ) -> [MangaVisionRegion] {
        let shape = output.shape.map(\.intValue)
        guard shape.count == 3,
              shape[0] == 1,
              analysisImageSize.width > 0,
              analysisImageSize.height > 0 else { return [] }

        let rowMajor: Bool
        let instanceCount: Int
        let featureCount: Int
        if shape[2] >= 6, shape[2] <= 256 {
            rowMajor = true
            instanceCount = shape[1]
            featureCount = shape[2]
        } else if shape[1] >= 6, shape[1] <= 256 {
            rowMajor = false
            instanceCount = shape[2]
            featureCount = shape[1]
        } else {
            return []
        }
        guard featureCount >= 6 else { return [] }

        func value(instance: Int, feature: Int) -> Double {
            let indices: [NSNumber] = rowMajor
                ? [0, NSNumber(value: instance), NSNumber(value: feature)]
                : [0, NSNumber(value: feature), NSNumber(value: instance)]
            return output[indices].doubleValue
        }

        var regions: [MangaVisionRegion] = []
        regions.reserveCapacity(min(instanceCount, 96))
        for index in 0..<instanceCount {
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
            let rect = MangaPageCoordinateSpace.sourceNormalizedRectFromScaleFitXYXY(
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2,
                inputSize: inputSize,
                sourceSize: analysisImageSize
            )
            guard rect.width > 0.002, rect.height > 0.002 else { continue }
            regions.append(MangaVisionRegion(
                type: type,
                normalizedRect: rect,
                confidence: confidence
            ))
        }
        return regions
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
