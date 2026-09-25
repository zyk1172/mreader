import CoreGraphics
import CoreML
import Foundation

/// Frozen class order exported by MangaLayout4 V1. This mapping is intentionally
/// independent from the legacy V2B5 five-class contract.
nonisolated enum MangaLayout4V1Class: Int, CaseIterable, Sendable {
    case frame = 0
    case text = 1
    case balloon = 2
    case onomatopoeia = 3

    var regionType: MangaRegionType {
        switch self {
        case .frame: .panel
        case .text: .text
        case .balloon: .balloon
        case .onomatopoeia: .onomatopoeia
        }
    }

    var semanticName: String {
        switch self {
        case .frame: "frame"
        case .text: "text"
        case .balloon: "balloon"
        case .onomatopoeia: "onomatopoeia"
        }
    }
}

nonisolated struct MangaLayout4V1OutputSpec: Sendable, Equatable {
    let name: String
    let level: String
    let role: String
    let channels: Int
    let height: Int
    let width: Int
    let stride: Int
}

nonisolated enum MangaLayout4V1OutputContract {
    static let revision = "manga-layout4-v1-raw-output-v1"
    static let inputFeatureName = "image"
    static let inputShape = [1, 3, 640, 640]
    static let prototypeCount = 8
    static let classCount = 4

    static let specs: [MangaLayout4V1OutputSpec] = [
        spec("p2_cls", "p2", "classification", 4, 160, 160, 4),
        spec("p2_bbox", "p2", "bbox", 4, 160, 160, 4),
        spec("p2_mask_coeff", "p2", "mask_coeff", 8, 160, 160, 4),
        spec("p3_cls", "p3", "classification", 4, 80, 80, 8),
        spec("p3_bbox", "p3", "bbox", 4, 80, 80, 8),
        spec("p3_mask_coeff", "p3", "mask_coeff", 8, 80, 80, 8),
        spec("p4_cls", "p4", "classification", 4, 40, 40, 16),
        spec("p4_bbox", "p4", "bbox", 4, 40, 40, 16),
        spec("p4_mask_coeff", "p4", "mask_coeff", 8, 40, 40, 16),
        spec("p5_cls", "p5", "classification", 4, 20, 20, 32),
        spec("p5_bbox", "p5", "bbox", 4, 20, 20, 32),
        spec("p5_mask_coeff", "p5", "mask_coeff", 8, 20, 20, 32),
        spec("mask_prototypes", "mask", "prototypes", 8, 320, 320, 2)
    ]

    static var outputNames: Set<String> { Set(specs.map(\.name)) }

    static func spec(level: String, role: String) -> MangaLayout4V1OutputSpec? {
        specs.first { $0.level == level && $0.role == role }
    }

    static func spec(named name: String) -> MangaLayout4V1OutputSpec? {
        specs.first { $0.name == name }
    }

    static func validate(modelDescription: MLModelDescription) -> [String] {
        var violations: [String] = []
        guard let input = modelDescription.inputDescriptionsByName[inputFeatureName] else {
            return ["missing-input:\(inputFeatureName)"]
        }
        guard input.type == .multiArray,
              let constraint = input.multiArrayConstraint else {
            return ["input-is-not-multiarray"]
        }
        let actualInputShape = constraint.shape.map(\.intValue)
        if actualInputShape != inputShape {
            violations.append("input-shape:\(actualInputShape),expected=\(inputShape)")
        }
        if constraint.dataType != .float32 {
            violations.append("input-dtype:\(constraint.dataType),expected=float32")
        }

        let outputs = modelDescription.outputDescriptionsByName
        let actualNames = Set(outputs.keys)
        let missing = outputNames.subtracting(actualNames).sorted()
        let extra = actualNames.subtracting(outputNames).sorted()
        if !missing.isEmpty {
            violations.append("missing-outputs:\(missing.joined(separator: ","))")
        }
        if !extra.isEmpty {
            violations.append("unexpected-outputs:\(extra.joined(separator: ","))")
        }
        for output in specs {
            guard let description = outputs[output.name] else { continue }
            guard description.type == .multiArray,
                  let constraint = description.multiArrayConstraint else {
                violations.append("output-not-multiarray:\(output.name)")
                continue
            }
            let actualShape = constraint.shape.map(\.intValue)
            let expected = [1, output.channels, output.height, output.width]
            if actualShape != expected {
                violations.append("output-shape:\(output.name)=\(actualShape),expected=\(expected)")
            }
            if constraint.dataType != .float32 {
                violations.append("output-dtype:\(output.name)=\(constraint.dataType),expected=float32")
            }
        }
        return violations
    }

    static func rawOutputs(from provider: MLFeatureProvider) throws -> [String: MLMultiArray] {
        var result: [String: MLMultiArray] = [:]
        result.reserveCapacity(specs.count)
        for output in specs {
            guard let array = provider.featureValue(for: output.name)?.multiArrayValue else {
                throw MangaLayout4V1Error.missingOutput(output.name)
            }
            let actualShape = array.shape.map(\.intValue)
            let expectedShape = [1, output.channels, output.height, output.width]
            guard actualShape == expectedShape else {
                throw MangaLayout4V1Error.outputShape(
                    name: output.name,
                    actual: actualShape,
                    expected: expectedShape
                )
            }
            guard array.dataType == .float32 else {
                throw MangaLayout4V1Error.unsupportedDataType(
                    name: output.name,
                    actual: String(describing: array.dataType)
                )
            }
            result[output.name] = array
        }
        return result
    }

    private static func spec(
        _ name: String,
        _ level: String,
        _ role: String,
        _ channels: Int,
        _ height: Int,
        _ width: Int,
        _ stride: Int
    ) -> MangaLayout4V1OutputSpec {
        MangaLayout4V1OutputSpec(
            name: name,
            level: level,
            role: role,
            channels: channels,
            height: height,
            width: width,
            stride: stride
        )
    }
}

nonisolated struct MangaLayout4V1Configuration: Sendable, Equatable {
    /// Validation-calibrated candidates. These are intentionally configurable and
    /// must not be treated as permanent product constants.
    var frameScoreThreshold: Float = 0.40
    var textScoreThreshold: Float = 0.50
    var balloonScoreThreshold: Float = 0.30
    var onomatopoeiaScoreThreshold: Float = 0.30

    var frameNMSThreshold: Float = 0.35
    var textNMSThreshold: Float = 0.35
    var balloonNMSThreshold: Float = 0.35
    var onomatopoeiaNMSThreshold: Float = 0.35

    var balloonMaskThreshold: Float = 0.50
    var preNMSTopKPerLevel: Int = 1_200
    var maxDetections: Int = 300

    func scoreThreshold(for layoutClass: MangaLayout4V1Class) -> Float {
        switch layoutClass {
        case .frame: frameScoreThreshold
        case .text: textScoreThreshold
        case .balloon: balloonScoreThreshold
        case .onomatopoeia: onomatopoeiaScoreThreshold
        }
    }

    func nmsThreshold(for layoutClass: MangaLayout4V1Class) -> Float {
        switch layoutClass {
        case .frame: frameNMSThreshold
        case .text: textNMSThreshold
        case .balloon: balloonNMSThreshold
        case .onomatopoeia: onomatopoeiaNMSThreshold
        }
    }
}

nonisolated enum MangaLayout4V1Error: Error, Sendable, Equatable {
    case modelUnavailable
    case invalidContract([String])
    case invalidInput(String)
    case missingOutput(String)
    case outputShape(name: String, actual: [Int], expected: [Int])
    case unsupportedDataType(name: String, actual: String)
}
