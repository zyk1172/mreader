import CoreGraphics
import Foundation

nonisolated struct MangaVisionClassCalibration: Sendable, Equatable {
    let confidenceThreshold: Float
    let nmsIOUThreshold: CGFloat
    let containmentThreshold: CGFloat
}

/// MangaLayout4 V1-only adaptive merge calibration. The primary provider already
/// applies the Python-reference score thresholds and same-class NMS; these values
/// keep tile merging aligned with that four-class contract.
nonisolated struct MangaVisionCalibrationProfile: Sendable, Equatable {
    let revision: String
    let byRegionType: [MangaRegionType: MangaVisionClassCalibration]

    static let bundled = MangaVisionCalibrationProfile(
        revision: "manga-layout4-v1-adaptive-merge-2026-09-25-v1",
        byRegionType: [
            .panel: MangaVisionClassCalibration(
                confidenceThreshold: 0.40,
                nmsIOUThreshold: 0.35,
                containmentThreshold: 0.92
            ),
            .text: MangaVisionClassCalibration(
                confidenceThreshold: 0.50,
                nmsIOUThreshold: 0.35,
                containmentThreshold: 0.88
            ),
            .balloon: MangaVisionClassCalibration(
                confidenceThreshold: 0.30,
                nmsIOUThreshold: 0.35,
                containmentThreshold: 0.90
            ),
            .onomatopoeia: MangaVisionClassCalibration(
                confidenceThreshold: 0.30,
                nmsIOUThreshold: 0.35,
                containmentThreshold: 0.90
            )
        ]
    )

    var confidenceThresholds: [MangaRegionType: Float] {
        Dictionary(uniqueKeysWithValues: byRegionType.map { type, calibration in
            (type, calibration.confidenceThreshold)
        })
    }

    func calibration(for type: MangaRegionType) -> MangaVisionClassCalibration {
        byRegionType[type]!
    }

    func deduplicated(_ regions: [MangaVisionRegion], type: MangaRegionType) -> [MangaVisionRegion] {
        let calibration = calibration(for: type)
        return MangaVisionRegionPostProcessor.deduplicated(
            regions,
            iouThreshold: calibration.nmsIOUThreshold,
            containmentThreshold: calibration.containmentThreshold
        )
    }
}
