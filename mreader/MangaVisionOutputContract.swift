import CoreML
import Foundation

nonisolated struct MangaVisionDetectionTensorLayout: Sendable, Equatable {
    let rowMajor: Bool
    let instanceCount: Int
    let featureCount: Int
}

/// Versioned boundary between the bundled Core ML artifact and the YOLO adapter.
/// The adapter and regression tests call the same shape validator so a model export
/// cannot silently drift into a tensor layout that production no longer understands.
nonisolated enum MangaVisionOutputContract {
    static let revision = "manga-vision-yolo-seg-output-contract-v2"
    static let expectedInputSize = CGSize(width: 640, height: 640)
    static let requiredSemanticClasses: Set<MangaRegionType> = [.panel, .text, .balloon]

    static func detectionTensorLayout(for output: MLMultiArray) -> MangaVisionDetectionTensorLayout? {
        detectionTensorLayout(shape: output.shape.map(\.intValue))
    }

    static func detectionTensorLayout(shape: [Int]) -> MangaVisionDetectionTensorLayout? {
        guard shape.count == 3, shape.first == 1 else { return nil }
        if shape[2] >= 6,
           shape[2] <= 256,
           shape[1] >= 1,
           shape[1] <= 2_000 {
            return MangaVisionDetectionTensorLayout(
                rowMajor: true,
                instanceCount: shape[1],
                featureCount: shape[2]
            )
        }
        if shape[1] >= 6,
           shape[1] <= 256,
           shape[2] >= 1,
           shape[2] <= 2_000 {
            return MangaVisionDetectionTensorLayout(
                rowMajor: false,
                instanceCount: shape[2],
                featureCount: shape[1]
            )
        }
        return nil
    }

    static func firstDetectionTensorIndex(in arrays: [MLMultiArray]) -> Int? {
        arrays.firstIndex { detectionTensorLayout(for: $0) != nil }
    }

    static func validate(
        modelDescription: MLModelDescription,
        supportedRegionTypes: Set<MangaRegionType>
    ) -> [String] {
        var violations: [String] = []

        let imageInputs = modelDescription.inputDescriptionsByName.values.compactMap { feature -> MLImageConstraint? in
            guard feature.type == .image else { return nil }
            return feature.imageConstraint
        }
        guard let imageInput = imageInputs.first else {
            violations.append("missing-image-input")
            return violations
        }
        if imageInput.pixelsWide != Int(expectedInputSize.width)
            || imageInput.pixelsHigh != Int(expectedInputSize.height) {
            violations.append(
                "unexpected-image-input-size:\(imageInput.pixelsWide)x\(imageInput.pixelsHigh)"
            )
        }

        let multiArrayShapes = modelDescription.outputDescriptionsByName.values.compactMap { feature -> [Int]? in
            guard feature.type == .multiArray,
                  let constraint = feature.multiArrayConstraint else { return nil }
            return constraint.shape.map(\.intValue)
        }
        if !multiArrayShapes.contains(where: { detectionTensorLayout(shape: $0) != nil }) {
            violations.append("missing-compatible-detection-output")
        }
        let hasCompatibleSegmentationOutput = multiArrayShapes.contains { shape in
            guard shape.count == 4, shape.first == 1 else { return false }
            let nonBatch = Array(shape.dropFirst())
            return nonBatch.filter { $0 >= 4 }.count >= 2
        }
        if !hasCompatibleSegmentationOutput {
            violations.append("missing-compatible-segmentation-output")
        }

        let missingClasses = requiredSemanticClasses.subtracting(supportedRegionTypes)
        if !missingClasses.isEmpty {
            let names = missingClasses.map(\.rawValue).sorted().joined(separator: ",")
            violations.append("missing-semantic-classes:\(names)")
        }
        return violations
    }
}
